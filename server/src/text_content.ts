import { createHash, randomUUID } from 'node:crypto';
import type { DatabaseSync } from 'node:sqlite';

type Row = Record<string, any>;
/** Delivery IDs remain immutable; identical group content shares one editable version. */
export class TextContents {
  private db:DatabaseSync;
  constructor(db:DatabaseSync) {
    this.db=db;
    db.exec(`CREATE TABLE IF NOT EXISTS text_contents(id TEXT PRIMARY KEY,group_id TEXT NOT NULL,digest TEXT NOT NULL,text TEXT NOT NULL,revision INTEGER NOT NULL,edited_at TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS text_contents_digest ON text_contents(group_id,digest);
      CREATE TABLE IF NOT EXISTS text_deliveries(event_id TEXT PRIMARY KEY,content_id TEXT NOT NULL,source TEXT NOT NULL,target TEXT NOT NULL,request_text TEXT NOT NULL,created TEXT NOT NULL,expires INTEGER NOT NULL,cursor INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS text_deliveries_content ON text_deliveries(content_id);
      CREATE INDEX IF NOT EXISTS text_deliveries_source ON text_deliveries(source);
      CREATE INDEX IF NOT EXISTS text_deliveries_target ON text_deliveries(target);`);
    // Upgrade surviving messages without changing their IDs, times or delivery cursors.
    for(const event of this.all("SELECT events.*,devices.group_id FROM events JOIN devices ON devices.id=events.source WHERE type='text.created' ORDER BY cursor")) {
      const payload=JSON.parse(event.payload);
      if(!payload.clipboard)this.attach(event,payload.text,event.group_id);
    }
  }
  private all(sql:string,...args:any[]){return this.db.prepare(sql).all(...args) as Row[];}
  private get(sql:string,...args:any[]){return this.db.prepare(sql).get(...args) as Row|undefined;}
  private run(sql:string,...args:any[]){return this.db.prepare(sql).run(...args);}
  private digest(text:string){return createHash('sha256').update(text,'utf8').digest('hex');}
  attach(event:Row,text:string,groupId:string) {
    const previous=this.get('SELECT * FROM text_deliveries WHERE event_id=?',event.id);
    if(previous)return this.document(previous.content_id);
    const hash=this.digest(text);
    let content=this.get('SELECT * FROM text_contents WHERE group_id=? AND digest=? AND text=?',groupId,hash,text);
    if(!content){content={id:randomUUID(),revision:1,edited_at:''};this.run('INSERT INTO text_contents VALUES(?,?,?,?,?,?)',content.id,groupId,hash,text,1,'');}
    this.run('INSERT INTO text_deliveries VALUES(?,?,?,?,?,?,?,?)',event.id,content.id,event.source,event.target,text,event.created,event.expires,event.cursor);
    return this.document(content.id);
  }
  delivery(eventId:string){return this.get('SELECT * FROM text_deliveries WHERE event_id=?',eventId);}
  document(id:string,deviceId?:string) {
    const content=this.get('SELECT * FROM text_contents WHERE id=?',id)!;
    const deliveries=deviceId?this.all('SELECT event_id FROM text_deliveries WHERE content_id=? AND (source=? OR target=?)',id,deviceId,deviceId):this.all('SELECT event_id FROM text_deliveries WHERE content_id=?',id);
    return {contentId:id,text:content.text as string,revision:content.revision as number,editedAt:content.edited_at as string,sourceEventIds:deliveries.map(row=>row.event_id as string)};
  }
  latest(deviceId:string) {
    return this.all('SELECT DISTINCT content_id FROM text_deliveries WHERE source=? OR target=?',deviceId,deviceId).map(row=>this.document(row.content_id,deviceId));
  }
  edit(eventId:string,text:string) {
    const delivery=this.delivery(eventId)!;
    const current=this.get('SELECT * FROM text_contents WHERE id=?',delivery.content_id)!;
    if(current.text===text)return {document:this.document(current.id),deliveries:[] as Row[]};
    const same=this.get('SELECT * FROM text_contents WHERE group_id=? AND digest=? AND text=? AND id<>?',current.group_id,this.digest(text),text,current.id);
    const revision=Math.max(current.revision,same?.revision || 0)+1,editedAt=new Date().toISOString();
    if(same){this.run('UPDATE text_deliveries SET content_id=? WHERE content_id=?',current.id,same.id);this.run('DELETE FROM text_contents WHERE id=?',same.id);}
    this.run('UPDATE text_contents SET text=?,digest=?,revision=?,edited_at=? WHERE id=?',text,this.digest(text),revision,editedAt,current.id);
    const document=this.document(current.id),deliveries=this.all('SELECT * FROM text_deliveries WHERE content_id=?',current.id);
    for(const row of deliveries){const event=this.get('SELECT payload FROM events WHERE id=?',row.event_id);if(event)this.run('UPDATE events SET payload=? WHERE id=?',JSON.stringify({...JSON.parse(event.payload),...document}),row.event_id);}
    return {document,deliveries};
  }
}
