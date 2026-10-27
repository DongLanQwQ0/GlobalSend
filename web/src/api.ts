import type { Session } from './model';

export class ApiError extends Error {
  constructor(public status: number, public code: string, message: string) { super(message); }
}
export class Api {
  constructor(public readonly baseUrl: string, public session: Session|null = null) {}
  async request<T>(path: string, body?: unknown, method = body === undefined ? 'GET' : 'POST', signal?:AbortSignal): Promise<T> {
    const headers: Record<string,string> = {};
    if (this.session) headers.Authorization = `Bearer ${this.session.deviceToken}`;
    if (body !== undefined) headers['Content-Type'] = 'application/json';
    const controller = new AbortController();
    const abort=()=>controller.abort();signal?.addEventListener('abort',abort,{once:true});if(signal?.aborted)controller.abort();
    const timer = setTimeout(() => controller.abort(), 20000);
    try {
      const response = await fetch(`${this.baseUrl}/api/v1${path}`, {
        method, headers, body: body === undefined ? undefined : JSON.stringify(body),
        signal: controller.signal, redirect: 'error', credentials: 'omit', cache: 'no-store',
      });
      const data = await response.json().catch(() => null);
      if(signal?.aborted)throw new DOMException('操作已停止','AbortError');
      if (!response.ok) throw new ApiError(response.status, data?.error?.code || 'HTTP_ERROR', data?.error?.message || `请求失败 (${response.status})`);
      return data as T;
    } catch (error) {
      if(signal?.aborted)throw new DOMException('操作已停止','AbortError');
      if (error instanceof ApiError) throw error;
      if (error instanceof DOMException && error.name === 'AbortError') throw new Error('连接超时，请重试。');
      throw new Error('无法连接，请检查网络后重试。');
    } finally { clearTimeout(timer);signal?.removeEventListener('abort',abort); }
  }
  upload<T>(path: string, bytes: Blob, onProgress: (loaded: number) => void, signal: AbortSignal): Promise<T> {
    return new Promise((resolve,reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open('PUT', `${this.baseUrl}/api/v1${path}`);
      xhr.setRequestHeader('Content-Type','application/octet-stream');
      if (this.session) xhr.setRequestHeader('Authorization',`Bearer ${this.session.deviceToken}`);
      xhr.timeout = 60000;
      xhr.upload.onprogress = event => onProgress(event.loaded);
      const abort = () => xhr.abort();
      signal.addEventListener('abort',abort,{once:true});
      const cleanup = () => signal.removeEventListener('abort',abort);
      xhr.onload = () => {
        cleanup();
        let data;
        try { data = JSON.parse(xhr.responseText); } catch { reject(new Error('中心返回了无效响应。')); return; }
        if (xhr.status >= 200 && xhr.status < 300) resolve(data as T);
        else reject(new ApiError(xhr.status,data?.error?.code || 'UPLOAD_FAILED',data?.error?.message || '上传失败'));
      };
      xhr.onerror = () => { cleanup(); reject(new Error('上传连接中断。可重试继续已提交的部分。')); };
      xhr.ontimeout = () => { cleanup(); reject(new Error('上传超时。可重试继续已提交的部分。')); };
      xhr.onabort = () => { cleanup(); reject(new DOMException('已暂停上传','AbortError')); };
      if (signal.aborted) { cleanup(); reject(new DOMException('已暂停上传','AbortError')); return; }
      xhr.send(bytes);
    });
  }
}
