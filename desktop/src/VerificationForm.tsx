import { useId, useState } from 'react';
import type { VerificationChallenge, VerificationReply } from './types';

export default function VerificationForm({challenge,onReply}:{
  challenge:VerificationChallenge;onReply:(answer:VerificationReply)=>Promise<void>;
}){
  const numbers=challenge.detail?.numbers||[];
  const numberField=useId();
  const [code,setCode]=useState('');
  const [number,setNumber]=useState(String(challenge.detail?.selectedNumberId??numbers[0]?.id??''));
  const [sending,setSending]=useState(false);
  const [error,setError]=useState('');
  async function reply(answer:VerificationReply){
    setSending(true);setError('');
    try{await onReply(answer);}catch(error){setError((error as Error).message);setSending(false);}
  }
  return <form className="form-stack" onSubmit={event=>{event.preventDefault();if(code.length===6&&!sending)void reply({action:'submit',code});}}>
    <label>Verification code<input className="verification-code" inputMode="numeric" autoComplete="one-time-code" autoFocus maxLength={6} value={code} disabled={sending} onChange={event=>setCode(event.target.value.replace(/\D/g,''))}/></label>
    {(error||challenge.detail?.lastError)&&<p className="error-text" role="alert">{error||challenge.detail?.lastError}</p>}
    <div className="dialog-actions"><button className="button" type="button" disabled={sending} onClick={()=>void reply({action:'resend'})}>Send another code</button><button className="button primary" disabled={sending||code.length!==6} type="submit">{sending?'Sending…':'Verify'}</button></div>
    <details className="verification-options"><summary>Other verification options</summary><div className="form-stack">
      {numbers.length>0&&<><div className="form-field"><label htmlFor={numberField}>Trusted phone number</label><select id={numberField} value={number} disabled={sending} onChange={event=>setNumber(event.target.value)}>{numbers.map(item=><option key={item.id} value={item.id}>Phone ending in {item.lastTwoDigits}</option>)}</select></div><button className="button" type="button" disabled={sending||!numbers.some(item=>String(item.id)===number)} onClick={()=>void reply({action:'sms',numberId:Number(number)})}>Send text message</button></>}
      <button className="text-button" type="button" disabled={sending} onClick={()=>void reply({action:'devices'})}>Send to trusted Apple devices</button>
    </div></details>
  </form>;
}
