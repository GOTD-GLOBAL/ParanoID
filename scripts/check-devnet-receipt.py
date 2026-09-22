"""Read-only deployment citation gate; no wallets or transaction submission."""
import base64
import hashlib
import json
import urllib.request

SBF_SHA='ab3517cb30be9832344f46638373bfd305f954619f3a95a6513d4981a4f93efa'

def verify_accounts(accounts):
    if not isinstance(accounts,list) or len(accounts)!=2 or any(not isinstance(a,dict) for a in accounts):
        raise ValueError('Program or ProgramData missing')
    program,data=accounts
    loader='BPFLoaderUpgradeab1e11111111111111111111111'
    if program.get('owner')!=loader or data.get('owner')!=loader or program.get('executable') is not True or data.get('executable') is not False:
        raise ValueError('Wrong loader or executable flags')
    decoded=[]
    for account in accounts:
        encoded=account.get('data')
        if not isinstance(encoded,list) or len(encoded)!=2 or encoded[1]!='base64':
            raise ValueError('Wrong account encoding')
        decoded.append(base64.b64decode(encoded[0],validate=True))
    p,d=decoded
    if p!=bytes([2,0,0,0])+base64.b64decode('JWY9XRDw+3elIwbt3hyMEQ6LYyvXj8Yb6HKt7rcPMtE='):
        raise ValueError('Wrong ProgramData linkage')
    if len(d)!=73845 or d[:4]!=bytes([3,0,0,0]) or d[12]!=1 or d[13:45]!=base64.b64decode('Rj7EwqG3Ted9Uycw3tEu/6sZhMVUHYCT9xhL64aDLMg='):
        raise ValueError('Wrong ProgramData size, tag or authority')
    if hashlib.sha256(d[45:]).hexdigest()!=SBF_SHA:
        raise ValueError('Deployed bytecode does not match reviewed artifact')

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        raise ValueError('RPC redirects are forbidden')


def rpc(method,params):
    if method not in ('getGenesisHash','getMultipleAccounts','getSignatureStatuses'):
        raise ValueError('Not an allowed read-only RPC method')
    request=urllib.request.Request('https://api.devnet.solana.com',
        data=json.dumps({'jsonrpc':'2.0','id':1,'method':method,'params':params}).encode(),
        headers={'Content-Type':'application/json'})
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}),NoRedirect())
    with opener.open(request,timeout=25) as response:raw=response.read(262145)
    if len(raw)>262144:raise ValueError('Oversized RPC response')
    result=json.loads(raw)
    if result.get('jsonrpc')!='2.0' or result.get('id')!=1 or 'error' in result or 'result' not in result:
        raise ValueError('Invalid or failed RPC response')
    return result['result']

def check(rpc):
    if rpc('getGenesisHash',[])!='EtWTRABZaYq6iMfeYKouRu166VU2xqa1wcaWoxPkrZBG':
        raise ValueError('Wrong network')
    response=rpc('getMultipleAccounts',[
        ['C8e5quz3JqepRZ4Mgj4L6PctGfdFpEo52t66WPBpgvas','3WzWMcWhaZtbCGubaJHUfVRm5edgkr4amWLWdHVkQLFr'],
        {'commitment':'finalized','encoding':'base64'}])
    verify_accounts(response['value'])
    statuses=rpc('getSignatureStatuses',[
        ['4dFfANwtzdq6iEwBM1GTd2iYLFowe3xXQBrBPYdjqxPSAwVPT6VNP3EnCuLwuHzhdJDc6NT3tywRYrCxyMk6PH1a'],
        {'searchTransactionHistory':True}])['value']
    if len(statuses)!=1:raise ValueError('Missing deployment status')
    verify_status(statuses[0])

def verify_status(status):
    if not isinstance(status, dict) or status.get('confirmationStatus') != 'finalized' or 'err' not in status or status.get('err') is not None or status.get('slot') != 502240101:
        raise ValueError('Deployment is not the recorded successful finalized transaction')

if __name__=='__main__':
    check(rpc)
    print('Devnet citation gate PASS: live genesis, finalized program/authority/bytecode and deployment signature')
