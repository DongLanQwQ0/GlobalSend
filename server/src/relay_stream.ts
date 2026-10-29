import { open, type FileHandle } from "node:fs/promises";
import { Readable } from "node:stream";

/** Tail committed bytes, retaining the final byte until upload verification. */
export function liveRelayStream(options: {
  path:string; size:number; start:number; end:number;
  state:()=>{active:boolean; ready:boolean; committed:number};
  subscribe:(wake:()=>void)=>()=>void;
}):Readable {
  let stopped=false,wake:(()=>void)|undefined;
  const unsubscribe=options.subscribe(()=>wake?.());
  async function* bytes() {
    let handle:FileHandle|undefined,position=options.start;
    try {
      while(!stopped && position<=options.end) {
        const state=options.state();
        if(!state.active)throw new Error("Relay file attempt ended");
        const available=Math.min(options.end,state.committed-1,
          state.ready?options.end:options.size-2);
        if(position<=available) {
          handle ||= await open(options.path,"r");
          const buffer=Buffer.allocUnsafe(Math.min(64*1024,available-position+1));
          const {bytesRead}=await handle.read(buffer,0,buffer.length,position);
          if(!bytesRead)throw new Error("Committed relay bytes are missing");
          position+=bytesRead;yield buffer.subarray(0,bytesRead);
        } else await new Promise<void>(resolve=>{
          const timer=setTimeout(finish,1000);
          function finish(){clearTimeout(timer);wake=undefined;resolve();}
          wake=finish;
        });
      }
    } finally {unsubscribe();wake?.();await handle?.close();}
  }
  const stream=Readable.from(bytes(),{objectMode:false});
  stream.once("close",()=>{stopped=true;unsubscribe();wake?.();});
  return stream;
}
