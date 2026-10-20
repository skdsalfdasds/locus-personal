"""Validate ephemeral native prompts without persisting verification secrets."""
import re


def verification_answer(prompt, answer):
    if not isinstance(answer,dict):raise ValueError('Choose a verification action.')
    action=answer.get('action')
    if action=='abort':return {'action':'abort'}
    if prompt.get('kind')!='twoFactor':raise ValueError('This verification prompt is unsupported.')
    if action=='submit':
        code=answer.get('code')
        if not isinstance(code,str) or not re.fullmatch(r'[0-9]{6}',code):
            raise ValueError('Enter the six-digit verification code.')
        return {'action':'submit','code':code}
    if action=='sms':
        identifier=answer.get('numberId')
        detail=prompt.get('detail')
        numbers=detail.get('numbers',[]) if isinstance(detail,dict) else []
        if not isinstance(numbers,list):numbers=[]
        if type(identifier) is not int or not any(
                isinstance(number,dict) and type(number.get('id')) is int and number['id']==identifier
                for number in numbers):
            raise ValueError('Select a trusted phone number from this prompt.')
        return {'action':'sms','numberId':identifier}
    if action in {'devices','resend'}:return {'action':action}
    raise ValueError('Choose a supported verification action.')
