export const FILE_CATEGORIES=['image','video','audio','text','archive','other'] as const;
export type FileCategory=(typeof FILE_CATEGORIES)[number];
export interface CleanupPreferences {retentionHours:number;categories:FileCategory[];sizeRule:'any'|'greater'|'smaller'|'atMost';sizeMiB:number}
export const defaultCleanup=():CleanupPreferences=>({retentionHours:24,categories:['image','text'],sizeRule:'atMost',sizeMiB:500000/1048576});
const extensions:Record<Exclude<FileCategory,'other'>,string[]>= {
  image:['png','jpg','jpeg','webp','gif','bmp','heic','heif','tif','tiff','svg'],
  video:['mp4','mov','mkv','webm','avi','3gp','flv','wmv','m4v'],
  audio:['mp3','wav','flac','aac','m4a','ogg','opus','wma','aiff'],
  text:['txt','md','markdown','log','json','jsonl','csv','tsv','xml','yaml','yml','ini','conf','config','toml','html','htm','css','js','ts','dart','java','kt','py','c','cpp','h','sh','ps1'],
  archive:['zip','rar','7z','tar','gz','bz2','xz','tgz','zst'],
};
export function fileCategory(name:string):FileCategory {
  const extension=name.split('.').pop()?.toLowerCase() || '';
  for(const category of Object.keys(extensions) as Exclude<FileCategory,'other'>[])if(extensions[category].includes(extension))return category;
  return 'other';
}
export function validateCleanup(value:CleanupPreferences):CleanupPreferences {
  if(!Number.isInteger(value.retentionHours) || value.retentionHours<1)throw new Error('保留时长至少 1 小时');
  if(!Number.isFinite(value.sizeMiB) || value.sizeMiB<0)throw new Error('请输入有效的文件大小');
  if(!['any','greater','smaller','atMost'].includes(value.sizeRule) || !value.categories.every(category=>FILE_CATEGORIES.includes(category)))throw new Error('清理规则无效');
  return {retentionHours:value.retentionHours,categories:[...new Set(value.categories)],sizeRule:value.sizeRule,sizeMiB:value.sizeMiB};
}
export function cleanupMatches(file:{name:string;size:number},rules:CleanupPreferences) {
  return rules.categories.includes(fileCategory(file.name)) && (rules.sizeRule==='any' || (rules.sizeRule==='greater'?file.size>rules.sizeMiB*1048576:rules.sizeRule==='atMost'?file.size<=rules.sizeMiB*1048576:file.size<rules.sizeMiB*1048576));
}
export function cleanupDue(file:{name:string;size:number;receivedAt:number},rules:CleanupPreferences,now=Date.now()) {
  return file.receivedAt+rules.retentionHours*3600000<=now && cleanupMatches(file,rules);
}
