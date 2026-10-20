"""Account lifecycle. Session secrets never leave the private backend pipe/vault."""
import asyncio
import json


def public_account(value):
    if not isinstance(value,dict) or not isinstance(value.get('email'),str):
        raise ValueError('The signing service returned invalid account metadata.')
    def team(item):
        return {key:item.get(key) for key in ('id','name','kind')} if isinstance(item,dict) else None
    return {'email':value['email'],'team':team(value.get('team')),
            'teams':[team(item) for item in value.get('teams',[]) if isinstance(item,dict)]}


def preferences(backend,remember,saved):
    values={**backend.settings(),'rememberSession':bool(remember),'sessionSaved':bool(saved)}
    backend.db.execute('INSERT OR REPLACE INTO settings VALUES (1,?)',(json.dumps(values),))
    backend.db.commit()


async def remember(backend,enabled):
    had_saved=backend.session_store.exists()
    # Invalidate the previous association first: a failed save for a new account
    # must never cause the old account to be restored on the next launch.
    preferences(backend,enabled,False)
    backend.session_state={'saved':False,'restored':False,'status':'none'}
    try:
        if enabled:
            secret=await backend.native_call('account.exportSession',{})
            try:await asyncio.to_thread(backend.session_store.save,secret)
            finally:secret=None
            preferences(backend,True,True)
            backend.session_state={'saved':True,'restored':False,'status':'saved'}
        elif had_saved:
            await asyncio.to_thread(backend.session_store.forget)
    except Exception:
        backend.session_state={'saved':False,'restored':False,'status':'unavailable',
            'message':'Signed in for this session. The saved sign-in could not be updated securely.'}


async def login(backend,params):
    async with backend.account_lock:
        # Only public native account metadata is returned. The export below is
        # a separate internal method, absent from Electron's RPC allowlist.
        backend.account=public_account(await backend.native_call('account.login',{
            key:params[key] for key in ('email','password','anisetteUrl','teamId') if key in params}))
        await remember(backend,params.get('rememberSession') is True)
        return backend.account


async def restore(backend):
    async with backend.account_lock:
        settings=backend.settings()
        if backend.native and backend.native.returncode is not None:backend.account=None
        if backend.account:return backend.account
        if not settings.get('rememberSession') or not settings.get('sessionSaved') or not backend.session_store.exists():
            return None
        backend.session_state={'saved':True,'restored':False,'status':'restoring'}
        try:
            secret=await asyncio.to_thread(backend.session_store.load)
            if secret is None:raise ValueError('No saved session')
            try:info=await backend.native_call('account.restoreSession',{'session':secret})
            finally:secret=None
            backend.account=public_account(info)
            backend.session_state={'saved':True,'restored':True,'status':'restored'}
            return backend.account
        except Exception:
            # A network outage is not proof of expired credentials. Retain the
            # encrypted cache; retry only at explicit user request/next launch.
            backend.session_state={'saved':True,'restored':False,'status':'unavailable',
                'message':'The saved sign-in could not be restored. Reconnect or sign in again.'}
            return None


async def logout(backend):
    async with backend.account_lock:
        saved=backend.settings().get('sessionSaved') or backend.session_store.exists()
        preferences(backend,False,False)
        backend.session_state={'saved':False,'restored':False,'status':'none'}
        warning=None
        if saved:
            try:await asyncio.to_thread(backend.session_store.forget)
            except Exception:warning='Signed out. A credential-store cleanup could not finish; automatic sign-in is disabled.'
        try:
            if backend.native and backend.native.returncode is None:
                await backend.native_call('account.logout',{})
        finally:backend.account=None
        if warning:backend.session_state.update(status='unavailable',message=warning)
        return {'ok':True,**({'warning':warning} if warning else {})}


async def select_team(backend,identifier):
    async with backend.account_lock:
        if not backend.account:raise ValueError('Sign in before selecting a developer team.')
        backend.account=public_account(await backend.native_call('account.selectTeam',{'teamId':identifier}))
        if backend.settings().get('rememberSession'):
            await remember(backend,True)
        return backend.account
