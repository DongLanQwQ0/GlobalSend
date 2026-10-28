type FullscreenDocument=Document & {webkitFullscreenElement?:Element;webkitFullscreenEnabled?:boolean;webkitExitFullscreen?:()=>Promise<void>|void;};
type FullscreenRoot=HTMLElement & {webkitRequestFullscreen?:()=>Promise<void>|void;};

/** Browser chrome can only be hidden through a supported, user-initiated mode. */
export class PageDisplay {
  hint='';
  private doc:Document;private win:Window;private changed:()=>void;
  constructor(doc:Document,win:Window,changed:()=>void){
    this.doc=doc;this.win=win;this.changed=changed;
    doc.addEventListener('fullscreenchange',changed);doc.addEventListener('webkitfullscreenchange',changed);
  }
  get active(){return !!(this.doc.fullscreenElement || (this.doc as FullscreenDocument).webkitFullscreenElement);}
  get standalone(){return !!(this.win.navigator as Navigator & {standalone?:boolean}|undefined)?.standalone || !!this.win.matchMedia?.('(display-mode: standalone)').matches || !!this.win.matchMedia?.('(display-mode: fullscreen)').matches;}
  get supported(){const root=this.doc.documentElement as FullscreenRoot,doc=this.doc as FullscreenDocument;return !!(typeof root.requestFullscreen==='function' && doc.fullscreenEnabled!==false || root.webkitRequestFullscreen && doc.webkitFullscreenEnabled!==false);}
  get label(){return this.active?'退出全屏':this.standalone?'独立窗口':'全屏';}
  async toggle(){
    const root=this.doc.documentElement as FullscreenRoot,doc=this.doc as FullscreenDocument;
    try{
      if(this.active){if(doc.exitFullscreen)await doc.exitFullscreen();else await doc.webkitExitFullscreen?.();}
      else if(this.standalone){this.hint='已从主屏幕独立打开';}
      else if(this.supported){if(typeof root.requestFullscreen==='function' && doc.fullscreenEnabled!==false)await root.requestFullscreen({navigationUI:'hide'});else await root.webkitRequestFullscreen?.();this.hint='';}
      else this.hint='在浏览器菜单中选择“添加到主屏幕”，再从桌面打开';
    }catch{this.hint='浏览器未允许全屏，可添加到主屏幕后打开';}
    this.changed();
  }
}
