import { Buffer } from 'buffer';
export { Buffer };
export class TextDecoder {
  constructor(private encoding = 'utf-8', _options: { fatal?: boolean } = {}) {}
  decode(input: Uint8Array): string {
    const bytes = Buffer.from(input);
    let text: string;
    if (this.encoding === 'utf-8') {
      text = bytes.toString('utf8');
      if (!Buffer.from(text, 'utf8').equals(bytes)) throw new Error('invalid UTF-8');
    } else if (this.encoding === 'utf-16le' || this.encoding === 'utf-16be') {
      if (bytes.length % 2) throw new Error('invalid UTF-16');
      const normalized = Buffer.from(bytes);
      if (this.encoding === 'utf-16be') normalized.swap16();
      text = normalized.toString('utf16le');
      for (let i=0;i<text.length;i++) {
        const n=text.charCodeAt(i);
        if (n>=0xd800&&n<=0xdbff) { const next=text.charCodeAt(++i); if (!(next>=0xdc00&&next<=0xdfff)) throw new Error('invalid UTF-16'); }
        else if (n>=0xdc00&&n<=0xdfff) throw new Error('invalid UTF-16');
      }
    } else throw new Error('unsupported encoding');
    return text.charCodeAt(0)===0xfeff ? text.slice(1) : text;
  }
}
export function checkpoint(): void {
  const callback=(globalThis as any).__macscopeCheckpoint;
  if (typeof callback === 'function') callback();
}
export function guardJSON(value: unknown): void {
  const stack: [unknown,number][]=[[value,0]]; let count=0;
  while(stack.length) {
    const [item,depth]=stack.pop()!;
    if (++count>500_000||depth>96) throw new Error('structural budget');
    if ((count&255)===0) checkpoint();
    if (typeof item==='number'&&!Number.isSafeInteger(item)&&Number.isInteger(item)) throw new Error('unsafe integer: use decimal/hex string');
    if (typeof item==='number'&&!Number.isFinite(item)) throw new Error('nonfinite number');
    if (typeof item==='string') {
      for(let i=0;i<item.length;i++) { const n=item.charCodeAt(i); if(n>=0xd800&&n<=0xdbff){const next=item.charCodeAt(++i);if(!(next>=0xdc00&&next<=0xdfff))throw new Error('unpaired surrogate');}else if(n>=0xdc00&&n<=0xdfff)throw new Error('unpaired surrogate'); }
    }
    if(item&&typeof item==='object') {
      const children=Array.isArray(item)?item:Object.entries(item).flatMap(([k,v])=>[k,v]);
      if(count+stack.length+children.length>500_000)throw new Error('structural budget');
      for(const child of children)stack.push([child,depth+1]);
    }
  }
}
export function canonical(value:any): string {
  if(value===null||typeof value!=='object')return JSON.stringify(value);
  if(Array.isArray(value))return '['+value.map(canonical).join(',')+']';
  return '{'+Object.keys(value).sort().filter(k=>value[k]!==undefined).map(k=>JSON.stringify(k)+':'+canonical(value[k])).join(',')+'}';
}
export function sha256UTF8(text:string):string {
  guardJSON(text);
  const fn=(globalThis as any).__macscopeSHA256;
  if(typeof fn!=='function')throw new Error('SHA256 host unavailable');
  const digest=fn(text);
  if(typeof digest!=='string'||!/^[a-f0-9]{64}$/.test(digest))throw new Error('invalid SHA256 host result');
  return digest;
}
export function sha256Base64(text:string):string {
  if(Buffer.from(text,'base64').toString('base64')!==text)throw new Error('noncanonical base64');
  const fn=(globalThis as any).__macscopeSHA256Base64;
  if(typeof fn!=='function')throw new Error('SHA256 host unavailable');
  const digest=fn(text);
  if(typeof digest!=='string'||!/^[a-f0-9]{64}$/.test(digest))throw new Error('invalid SHA256 host result');
  return digest;
}
