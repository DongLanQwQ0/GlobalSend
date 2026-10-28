export const appearanceModes = ['light','dark','neutral'] as const;
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
export function appearancePalette(value:Appearance) {
  const dark=value.mode==='dark',neutral=value.mode==='neutral';
  return {canvas:dark?'#121819':neutral?'#e9eaec':'#f4f6f2',
    surface:dark?'#1c2324':neutral?'#f7f7f8':'#ffffff',
    field:dark?'#242c2d':neutral?'#efeff1':'#fafcf9',
    text:dark?'#e6eeee':neutral?'#25272b':'#202923',
    muted:dark?'#a8b5b1':neutral?'#62666d':'#667068',
    line:dark?'#3b4748':neutral?'#d5d7dc':'#dfe6df',
    green:(dark?darkAccents:lightAccents)[accentColors.indexOf(value.accent)],
    'on-accent':dark?'#102321':'#ffffff',red:dark?'#ffb4a7':'#a94237',
    warning:dark?'#eac17c':'#85662b'};
}

export class AppearancePreferences {
  value:Appearance;
  private doc:Document; private read:()=>string|null; private write:(raw:string)=>void;
  constructor(doc:Document,read:()=>string|null,write:(raw:string)=>void){
    this.doc=doc;this.read=read;this.write=write;this.value=parseAppearance(read());this.apply();
  }
  reload(){this.value=parseAppearance(this.read());this.apply();}
  set(change:Partial<Appearance>){this.value=parseAppearance(JSON.stringify({...this.value,...change}));this.write(JSON.stringify(this.value));this.apply();}
  private apply(){
    const root=this.doc.documentElement;root.dataset.theme=this.value.mode;root.dataset.accent=this.value.accent;
    root.style.colorScheme=this.value.mode==='dark'?'dark':'light';
    const palette=appearancePalette(this.value);
    for(const [key,value] of Object.entries(palette))root.style.setProperty('--'+key,value);
    this.doc.querySelector('meta[name="theme-color"]')?.setAttribute('content',palette.canvas);
    root.style.setProperty('--soft',`color-mix(in srgb,var(--green) ${this.value.mode==='dark'?13:8}%,var(--surface))`);
    this.doc.querySelectorAll<HTMLButtonElement>('[data-appearance-mode]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.appearanceMode===this.value.mode)));
    this.doc.querySelectorAll<HTMLButtonElement>('[data-appearance-accent]').forEach(button=>{
      button.setAttribute('aria-pressed',String(button.dataset.appearanceAccent===this.value.accent));
      button.style.setProperty('--swatch',(this.value.mode==='dark'?darkAccents:lightAccents)[accentColors.indexOf(button.dataset.appearanceAccent as AccentColor)]);
    });
  }
  html(){return `<section class="settings-card appearance-settings"><h3>外观</h3><div class="appearance-modes" role="group" aria-label="主题">${appearanceModes.map((mode,index)=>`<button type="button" data-appearance-mode="${mode}" aria-pressed="${mode===this.value.mode}">${['亮色','暗色','中性'][index]}</button>`).join('')}</div><div class="appearance-accents" role="group" aria-label="主题颜色">${accentColors.map((accent,index)=>`<button type="button" data-appearance-accent="${accent}" aria-label="${accentLabels[index]}" title="${accentLabels[index]}" aria-pressed="${accent===this.value.accent}" style="--swatch:${(this.value.mode==='dark'?darkAccents:lightAccents)[index]}"><span></span></button>`).join('')}</div></section>`;}
}
