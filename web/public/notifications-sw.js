// Notifications only: no fetch handler, offline cache, persistent socket or Push
// subscription. A closed/suspended page cannot receive new GlobalSend messages.
self.addEventListener('install',event=>event.waitUntil(self.skipWaiting()));
self.addEventListener('activate',event=>event.waitUntil(self.clients.claim()));
self.addEventListener('notificationclick',event=>{
  event.notification.close();
  const data=event.notification.data;
  if(data?.type!=='globalsend.notification.open' || typeof data.itemId!=='string')return;
  event.waitUntil((async()=>{
    const scope=new URL(self.registration.scope);
    const clients=await self.clients.matchAll({type:'window',includeUncontrolled:true});
    const matching=clients.filter(client=>{
      const url=new URL(client.url);
      return url.origin===scope.origin && url.pathname.startsWith(scope.pathname);
    });
    const client=matching.find(client=>client.focused) ?? matching[0];
    if(client){
      // Focus first, then deliver the item to the current in-memory session.
      // There is no navigation/reload that could lose an in-progress transfer.
      try {await client.focus();client.postMessage({type:'globalsend.notification.open',itemId:data.itemId});return;}catch{}
    }
    const url=new URL(scope.href);
    url.hash=`gs-receipt=${encodeURIComponent(data.itemId)}`;
    await self.clients.openWindow(url.href);
  })());
});
