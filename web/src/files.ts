import { sha256 } from '@noble/hashes/sha2.js';

/** Incremental integrity digest: never reads more than 1 MiB of a file at once. */
export async function digestFile(file: Blob,options: {blockSize?:number;onProgress?:(done:number)=>void;signal?:AbortSignal} = {}): Promise<string> {
  const hash = sha256.create();
  const blockSize = Math.max(1,Math.min(options.blockSize || 1048576,1048576));
  for (let offset = 0;offset < file.size;offset += blockSize) {
    options.signal?.throwIfAborted();
    hash.update(new Uint8Array(await file.slice(offset,offset + blockSize).arrayBuffer()));
    options.onProgress?.(Math.min(file.size,offset + blockSize));
    await new Promise(resolve => setTimeout(resolve,0));
  }
  options.signal?.throwIfAborted();
  return Array.from(hash.digest(),byte => byte.toString(16).padStart(2,'0')).join('');
}
