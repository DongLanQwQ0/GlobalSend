const imageSuffixes=new Set(['png','jpg','jpeg','webp','gif','bmp','heic','heif','avif']);
const placeholderSuffixes=new Set(['pic','image','img','bin','tmp','dat']);
const mimeExtensions:Record<string,string>={
  'image/png':'png','image/jpeg':'jpg','image/webp':'webp','image/gif':'gif',
  'image/bmp':'bmp','image/heic':'heic','image/heif':'heif','image/avif':'avif',
};

/** Inspect only the container header; no decoding, transcoding or source rename. */
export function imageContainer(bytes:Uint8Array):{mimeType:string;extension:string}|null {
  const prefix=(value:number[]|string,offset=0)=>{
    const values=typeof value==='string'?[...value].map(character=>character.charCodeAt(0)):value;
    return bytes.length>=offset+values.length && values.every((value,index)=>bytes[offset+index]===value);
  };
  if(prefix([0xff,0xd8,0xff]))return {mimeType:'image/jpeg',extension:'jpg'};
  if(prefix([137,80,78,71,13,10,26,10]))return {mimeType:'image/png',extension:'png'};
  if(prefix('GIF87a') || prefix('GIF89a'))return {mimeType:'image/gif',extension:'gif'};
  if(prefix('BM'))return {mimeType:'image/bmp',extension:'bmp'};
  if(prefix('RIFF') && prefix('WEBP',8))return {mimeType:'image/webp',extension:'webp'};
  if(prefix('ftyp',4)){
    const brands=[...(bytes.length>=12?[String.fromCharCode(...bytes.subarray(8,12))]:[])];
    for(let at=16;at+4<=bytes.length;at+=4)brands.push(String.fromCharCode(...bytes.subarray(at,at+4)));
    if(brands.some(brand=>['avif','avis'].includes(brand)))return {mimeType:'image/avif',extension:'avif'};
    if(brands.some(brand=>['heic','heix','hevc','hevx'].includes(brand)))return {mimeType:'image/heic',extension:'heic'};
    if(brands.some(brand=>['mif1','msf1'].includes(brand)))return {mimeType:'image/heif',extension:'heif'};
  }
  return null;
}

export function imageFileName(name:string,extension:string):string {
  const dot=name.lastIndexOf('.'),suffix=dot>0?name.slice(dot+1).toLowerCase():'';
  if(suffix===extension || extension==='jpg' && suffix==='jpeg')return name;
  const replace=imageSuffixes.has(suffix) || placeholderSuffixes.has(suffix);
  return `${replace && dot>0?name.slice(0,dot):name}.${extension}`;
}

/** Metadata for a standalone offer; keep the original File for hash and payload. */
export async function imageFileMetadata(file:File,name=file.name,mimeType=file.type):Promise<{name:string;mimeType:string}> {
  const actual=imageContainer(new Uint8Array(await file.slice(0,32).arrayBuffer()));
  const hint=mimeType.toLowerCase().split(';')[0].trim();
  const extension=actual?.extension || mimeExtensions[hint];
  return {name:extension?imageFileName(name,extension):name,mimeType:actual?.mimeType || mimeType || 'application/octet-stream'};
}
