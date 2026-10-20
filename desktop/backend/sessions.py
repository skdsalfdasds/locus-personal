"""Encrypted session cache. The random encryption key lives only in an OS vault."""
import base64
import hashlib
import json
import os
from pathlib import Path
import tempfile

from cryptography.hazmat.primitives.ciphers.aead import AESGCM


class SessionUnavailable(RuntimeError):pass


def validate_session(value):
    fields={'version','email','token','adsid','duration','expiry','endpoint','teamId'}
    if not isinstance(value,dict) or set(value)!=fields or type(value.get('version')) is not int or value['version']!=1:
        raise SessionUnavailable('The saved signing session is invalid.')
    for field,limit in (('email',320),('token',16384),('adsid',64),('endpoint',2048),('teamId',128)):
        item=value[field]
        if not isinstance(item,str) or not item or len(item.encode('utf-8'))>limit:
            raise SessionUnavailable('The saved signing session is invalid.')
    if not value['adsid'].isascii() or not value['adsid'].isdigit() or not value['teamId'].isascii() or not value['teamId'].isalnum():
        raise SessionUnavailable('The saved signing session is invalid.')
    if '\r' in value['endpoint'] or '\n' in value['endpoint'] or any(type(value[field]) is not int or not 0<=value[field]<=2**64-1 for field in ('duration','expiry')):
        raise SessionUnavailable('The saved signing session is invalid.')
    return dict(value)


def secure_backend():
    import keyring
    allowed={'keyring.backends.Windows','keyring.backends.macOS','keyring.backends.OS_X',
             'keyring.backends.SecretService','keyring.backends.libsecret','keyring.backends.kwallet'}
    selected=keyring.get_keyring()
    candidates=selected.backends if type(selected).__module__=='keyring.backends.chainer' else [selected]
    for candidate in candidates:
        if type(candidate).__module__ in allowed and candidate.priority>0:return candidate
    raise SessionUnavailable('The operating system credential store is unavailable. Sign-in will work for this session only.')


class SessionStore:
    service='app.waypoint.desktop.signing-session.v1'
    def __init__(self,root,backend=None):
        self.root=Path(root).resolve();self.path=self.root/'signing-session.enc'
        scope=str(self.root).casefold() if os.name=='nt' else str(self.root)
        self.account=hashlib.sha256(scope.encode('utf-8')).hexdigest()
        self.context=(self.service+':'+self.account).encode('ascii')
        self.backend=backend

    def exists(self):return self.path.is_file()

    def _vault(self):return self.backend if self.backend is not None else secure_backend()

    def _key(self,vault,create=False):
        encoded=vault.get_password(self.service,self.account)
        if encoded is None and create:
            encoded=base64.b64encode(os.urandom(32)).decode('ascii')
            vault.set_password(self.service,self.account,encoded)
        try:key=base64.b64decode(encoded,validate=True)
        except (ValueError,TypeError):raise SessionUnavailable('The saved signing key is unavailable.') from None
        if len(key)!=32:raise SessionUnavailable('The saved signing key is unavailable.')
        return key

    def save(self,value):
        value=validate_session(value)
        data=json.dumps(value,ensure_ascii=True,separators=(',',':')).encode('utf-8')
        if len(data)>32768:raise SessionUnavailable('The signing session exceeds the storage limit.')
        temporary=None
        try:
            if self.path.is_symlink():raise SessionUnavailable('The signing session cache path is invalid.')
            self.root.mkdir(parents=True,exist_ok=True,mode=0o700)
            key=self._key(self._vault(),create=True);nonce=os.urandom(12)
            encrypted=b'WPS1'+nonce+AESGCM(key).encrypt(nonce,data,self.context)
            with tempfile.NamedTemporaryFile(dir=self.root,prefix='.session-',suffix='.enc',delete=False) as stream:
                temporary=Path(stream.name);stream.write(encrypted);stream.flush();os.fsync(stream.fileno())
            os.replace(temporary,self.path)
        except SessionUnavailable:raise
        except Exception:raise SessionUnavailable('The signing session could not be saved securely. Your password was not saved.') from None
        finally:
            if temporary is not None:temporary.unlink(missing_ok=True)

    def load(self):
        if not self.exists():return None
        try:
            if self.path.is_symlink() or self.path.stat().st_size>32800:
                raise SessionUnavailable('The saved signing session is invalid.')
            encrypted=self.path.read_bytes()
            if len(encrypted)<32 or encrypted[:4]!=b'WPS1':raise SessionUnavailable('The saved signing session is invalid.')
            key=self._key(self._vault())
            data=AESGCM(key).decrypt(encrypted[4:16],encrypted[16:],self.context)
            return validate_session(json.loads(data))
        except SessionUnavailable:raise
        except Exception:raise SessionUnavailable('The saved signing session could not be unlocked. Sign in again or unlock the system credential store.') from None

    def forget(self):
        try:
            # Delete ciphertext before the vault key, so a vault error cannot
            # silently leave an automatically restorable sign-in behind.
            self.path.unlink(missing_ok=True)
            vault=self._vault()
            from keyring.errors import PasswordDeleteError
            try:vault.delete_password(self.service,self.account)
            except PasswordDeleteError:pass
        except Exception:raise SessionUnavailable('The saved session was disabled, but its credential-store key could not be removed.') from None
