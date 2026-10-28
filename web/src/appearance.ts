export const appearanceModes = ['light','dark','neutral','system'] as const;
export const accentColors = ['green','blue','purple','rose','amber','slate'] as const;
export type AppearanceMode = typeof appearanceModes[number];
export type AccentColor = typeof accentColors[number];
export interface Appearance {mode:AppearanceMode;accent:AccentColor;}
export const appearanceKey='globalsend:appearance';
export function parseAppearance(raw:string|null):Appearance {
  let value:Partial<Appearance>={};
  try {value=JSON.parse(raw || '{}') || {};} catch { /* Keep the default for an old or incomplete preference. */ }
  return {mode:appearanceModes.includes(value.mode as AppearanceMode)?value.mode!:'light',
    accent:accentColors.includes(value.accent as AccentColor)?value.accent!:'green'};
}
const lightAccents=['#176b50','#245ea8','#7051a8','#a34363','#815c17','#4c6375'];
const darkAccents=['#81d6b4','#9ecaff','#c9b6ff','#f3aec0','#eac17c','#b7c9d8'];
const accentLabels=['绿','蓝','紫','玫瑰','琥珀','石板'];
function tint(accent:string,surface:string,opacity:number){
  const channel=(value:string,offset:number)=>parseInt(value.slice(offset,offset+2),16);
  return '#'+[1,3,5].map(offset=>Math.round(channel(accent,offset)*opacity+channel(surface,offset)*(1-opacity)).toString(16).padStart(2,'0')).join('');
}
export function appearancePalette(value:Appearance,systemDark=false) {
  const dark=value.mode==='dark'||value.mode==='system'&&systemDark,neutral=value.mode==='neutral';
  const accent=(dark?darkAccents:lightAccents)[accentColors.indexOf(value.accent)],surface=dark?'#202124':neutral?'#f7f7f8':'#ffffff';
  return {canvas:dark?'#141516':neutral?'#e9eaec':'#f5f5f6',surface,
    field:neutral?'#efeff1':tint(accent,surface,dark ? .055 : .03),
    text:dark?'#e9eaed':'#25272b',
    muted:dark?'#abb0b8':'#62666d',
    line:dark?'#3c4046':neutral?'#d5d7dc':'#dedfe3',green:accent,
    'on-accent':dark?'#16191d':'#ffffff',red:dark?'#ffb4a7':'#a94237',
    warning:dark?'#eac17c':'#85662b'};
}

export class AppearancePreferences {
  value:Appearance;
  private doc:Document; private read:()=>string|null; private write:(raw:string)=>void;
  private media:MediaQueryList|null;
  private systemChanged=()=>{if(this.value.mode==='system')this.apply();};
  constructor(doc:Document,read:()=>string|null,write:(raw:string)=>void,media:MediaQueryList|null=doc.defaultView?.matchMedia?.('(prefers-color-scheme: dark)')??null){
    this.doc=doc;this.read=read;this.write=write;this.media=media;this.value=parseAppearance(read());this.apply();
    media?.addEventListener('change',this.systemChanged);
  }
  dispose(){this.media?.removeEventListener('change',this.systemChanged);}
  private effectiveMode(){return this.value.mode==='system'?(this.media?.matches?'dark':'light'):this.value.mode;}
  reload(){this.value=parseAppearance(this.read());this.apply();}
  set(change:Partial<Appearance>){this.value=parseAppearance(JSON.stringify({...this.value,...change}));this.write(JSON.stringify(this.value));this.apply();}
  private apply(){
    const mode=this.effectiveMode();
    const root=this.doc.documentElement;root.dataset.theme=mode;root.dataset.themePreference=this.value.mode;root.dataset.accent=this.value.accent;
    root.style.colorScheme=mode==='dark'?'dark':'light';
    const palette=appearancePalette(this.value,this.media?.matches);
    for(const [key,value] of Object.entries(palette))root.style.setProperty('--'+key,value);
    this.doc.querySelector('meta[name="theme-color"]')?.setAttribute('content',palette.canvas);
    root.style.setProperty('--soft',`color-mix(in srgb,var(--green) ${mode==='dark'?13:8}%,var(--surface))`);
    this.doc.querySelectorAll<HTMLButtonElement>('[data-appearance-mode]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.appearanceMode===this.value.mode)));
    this.doc.querySelectorAll<HTMLButtonElement>('[data-appearance-accent]').forEach(button=>{
      button.setAttribute('aria-pressed',String(button.dataset.appearanceAccent===this.value.accent));
      button.style.setProperty('--swatch',(mode==='dark'?darkAccents:lightAccents)[accentColors.indexOf(button.dataset.appearanceAccent as AccentColor)]);
    });
  }
  html(){return `<section class="settings-card appearance-settings"><h3>外观</h3><div class="appearance-modes" role="group" aria-label="主题">${appearanceModes.map((mode,index)=>`<button type="button" data-appearance-mode="${mode}" aria-pressed="${mode===this.value.mode}">${['亮色','暗色','中性','跟随系统'][index]}</button>`).join('')}</div><div class="appearance-accents" role="group" aria-label="主题颜色">${accentColors.map((accent,index)=>`<button type="button" data-appearance-accent="${accent}" aria-label="${accentLabels[index]}" title="${accentLabels[index]}" aria-pressed="${accent===this.value.accent}" style="--swatch:${(this.effectiveMode()==='dark'?darkAccents:lightAccents)[index]}"><span></span></button>`).join('')}</div></section>`;}
}
