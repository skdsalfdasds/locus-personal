"""Independent verification of the thin ARM64 Waypoint export fixture.

This checks code-page and entitlement digests without using the Rust signer's
verification implementation. It never connects to an Apple device.
"""
import argparse
import hashlib
import hmac
import json
import plistlib
from pathlib import Path
import struct
import zipfile


def verify(binary, expected_entitlements=None):
    if binary[:4]!=b'\xcf\xfa\xed\xfe':
        raise ValueError('This fixture verifier requires a thin little-endian 64-bit executable.')
    commands=struct.unpack_from('<I',binary,16)[0]
    cursor=32;signature=None
    for _ in range(commands):
        command,length=struct.unpack_from('<II',binary,cursor)
        if length<8 or cursor+length>len(binary):raise ValueError('Invalid load command')
        if command==0x1d:
            offset,size=struct.unpack_from('<II',binary,cursor+8)
            signature=binary[offset:offset+size]
            if len(signature)!=size:raise ValueError('Truncated signature')
        cursor+=length
    if signature is None:raise ValueError('Missing code signature')
    magic,length,count=struct.unpack_from('>III',signature)
    if magic!=0xfade0cc0 or length>len(signature) or 12+count*8>length:
        raise ValueError('Invalid signature superblob')
    blobs={}
    for index in range(count):
        slot,offset=struct.unpack_from('>II',signature,12+8*index)
        _,size=struct.unpack_from('>II',signature,offset)
        if size<8 or offset+size>length or slot in blobs:raise ValueError('Invalid signature slot')
        blobs[slot]=signature[offset:offset+size]
    directory=blobs[0]
    magic,length,version,flags,hash_offset,_,special,slots,limit=struct.unpack_from('>9I',directory)
    hash_size,hash_type,_,page_exp=directory[36:40]
    if magic!=0xfade0c02 or not flags&2:raise ValueError('Missing ad-hoc code directory')
    if blobs.get(0x10000,b'')[8:]:raise ValueError('Ad-hoc output contains unexpected CMS data')
    if version>=0x20300 and limit==0xffffffff:limit=struct.unpack_from('>Q',directory,56)[0]
    if page_exp>30 or limit>len(binary):raise ValueError('Invalid signed code limit')
    page_size=1<<page_exp
    if slots!=(limit+page_size-1)//page_size:raise ValueError('Invalid code page count')
    if hash_offset<special*hash_size or hash_offset+slots*hash_size>length:
        raise ValueError('Invalid digest table')
    algorithms={1:'sha1',2:'sha256',3:'sha256',4:'sha384'}
    if hash_size!={1:20,2:32,3:20,4:48}[hash_type]:raise ValueError('Invalid digest size')
    algorithm=algorithms[hash_type]
    digest=lambda data:hashlib.new(algorithm,data).digest()[:hash_size]
    for index in range(slots):
        expected=directory[hash_offset+index*hash_size:hash_offset+(index+1)*hash_size]
        if not hmac.compare_digest(expected,digest(binary[index*page_size:min(limit,(index+1)*page_size)])):
            raise ValueError('Code page digest mismatch')
    entitlements=blobs.get(5)
    if expected_entitlements is not None:
        if entitlements is None or special<5:raise ValueError('Entitlements are not sealed')
        sealed=directory[hash_offset-5*hash_size:hash_offset-4*hash_size]
        if not hmac.compare_digest(sealed,digest(entitlements)):raise ValueError('Entitlement digest mismatch')
        if plistlib.loads(entitlements[8:].rstrip(b'\0'))!=expected_entitlements:
            raise ValueError('Exported entitlements do not match the requested dictionary')
    return slots


def main():
    parser=argparse.ArgumentParser();parser.add_argument('ipa',type=Path)
    parser.add_argument('--expect-task-allow',action='store_true');args=parser.parse_args()
    with zipfile.ZipFile(args.ipa) as archive:
        main=next(name for name in archive.namelist() if name.startswith('Payload/') and name.count('/')==2 and name.endswith('.app/Info.plist'))
        prefix=main.removesuffix('Info.plist')
        info=plistlib.loads(archive.read(main))
        binary=archive.read(prefix+info['CFBundleExecutable'])
        expected={'get-task-allow':True} if args.expect_task_allow else None
        pages=verify(binary,expected)
        if any(name.endswith('/embedded.mobileprovision') for name in archive.namelist()):
            raise ValueError('Ad-hoc export retained an Apple provisioning profile')
        # Negative control: changing signed header data must fail page validation.
        damaged=bytearray(binary);damaged[28]^=1
        try:verify(damaged,expected)
        except ValueError:pass
        else:raise AssertionError('Independent verifier accepted modified executable data')
    print(json.dumps({'verifiedCodePages':pages,'tamperRejected':True,'appleProvisioned':False}))


if __name__=='__main__':main()
