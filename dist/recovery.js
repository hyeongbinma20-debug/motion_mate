const key='bookit.password-recovery.v1';
export const recoveryRedirect='https://hyeongbinma20-debug.github.io/motion_mate/';
export function authMessage(error){const message=error?.message||String(error);if(/Failed to fetch|NetworkError|fetch failed/i.test(message))return '인터넷 연결을 확인하고 다시 시도해주세요.';if(/email address not authorized|email_address_not_authorized/i.test(message))return '현재 이 주소로 메일을 보낼 수 없어요. 운영자에게 문의해주세요.';if(/email rate limit|over_email_send_rate_limit/i.test(message))return '메일 발송 한도에 도달했어요. 잠시 후 다시 시도해주세요.';if(/invalid login credentials/i.test(message))return '이메일 또는 비밀번호가 올바르지 않아요.';if(/email not confirmed/i.test(message))return '가입 메일에서 이메일 확인을 먼저 완료해주세요.';if(/expired|invalid.*token|otp_expired/i.test(message))return '링크가 만료되었거나 이미 사용됐어요. 재설정 메일을 다시 요청해주세요.';return message;}
export function recoveryAccess(storage){return {
  grant(user){try{storage.setItem(key,JSON.stringify({user,time:Date.now()}));}catch{}},
  allowed(user){try{const value=JSON.parse(storage.getItem(key));return !!user&&value?.user===user&&Date.now()-value.time>=0&&Date.now()-value.time<15*60*1000;}catch{return false;}},
  clear(){try{storage.removeItem(key);}catch{}},
};}
export function validatePassword(password,confirmation){if(typeof password!=='string'||password.length<8)throw Error('비밀번호는 8자 이상 입력해주세요.');if(password.length>128)throw Error('비밀번호는 128자 이내로 입력해주세요.');if(password!==confirmation)throw Error('두 비밀번호가 일치하지 않아요.');return password;}
export function recoveryService(client,storage){const access=recoveryAccess(storage);let readyUser=null,readyAt=0,lastSent=0;
  return {
    event(event,session){if(event==='PASSWORD_RECOVERY'&&session?.user){readyUser=session.user.id;readyAt=Date.now();access.grant(readyUser);}if(event==='SIGNED_OUT'){readyUser=null;access.clear();}},
    allowed(user){return !!user&&((readyUser===user&&Date.now()-readyAt>=0&&Date.now()-readyAt<15*60*1000)||access.allowed(user));},
    async request(email){if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))throw Error('올바른 이메일 주소를 입력해주세요.');const wait=60000-(Date.now()-lastSent);if(wait>0)throw Error(`메일은 ${Math.ceil(wait/1000)}초 뒤 다시 요청할 수 있어요.`);lastSent=Date.now();const result=await client.auth.resetPasswordForEmail(email,{redirectTo:recoveryRedirect});if(result.error)throw Error(authMessage(result.error));},
    async update(user,password,confirmation){if(!this.allowed(user))throw Error('유효한 재설정 메일의 링크로 다시 접속해주세요.');validatePassword(password,confirmation);const result=await client.auth.updateUser({password});if(result.error)throw Error(authMessage(result.error));readyUser=null;access.clear();},
    clear(){readyUser=null;access.clear();},
  };
}
