import type { DatabaseSync } from 'node:sqlite';

type Row = Record<string, any>;
/** A device/token is an installation identity, not a group membership. */
export class DeviceGroups {
  private db: DatabaseSync;
  constructor(db: DatabaseSync) {
    this.db=db;
    db.exec(`CREATE TABLE IF NOT EXISTS device_groups(
      device_id TEXT NOT NULL,group_id TEXT NOT NULL,name TEXT NOT NULL,joined TEXT NOT NULL,
      PRIMARY KEY(device_id,group_id));
      CREATE INDEX IF NOT EXISTS device_groups_group ON device_groups(group_id,device_id);
      INSERT OR IGNORE INTO device_groups(device_id,group_id,name,joined)
        SELECT id,group_id,'分组 1',created FROM devices WHERE group_id<>'';`);
  }
  list(deviceId: string) {
    return (this.db.prepare('SELECT group_id AS groupId,name,joined AS joinedAt FROM device_groups WHERE device_id=? ORDER BY joined,group_id').all(deviceId) as Row[]);
  }
  has(deviceId: string, groupId: string): boolean {
    return !!this.db.prepare('SELECT 1 FROM device_groups WHERE device_id=? AND group_id=?').get(deviceId, groupId);
  }
  join(deviceId: string, groupId: string, name?: string) {
    this.db.prepare('INSERT OR IGNORE INTO device_groups VALUES(?,?,?,?)').run(deviceId,groupId,name?.trim() || `分组 ${this.list(deviceId).length+1}`,new Date().toISOString());
    this.db.prepare("UPDATE devices SET group_id=? WHERE id=? AND group_id=''").run(groupId,deviceId);
  }
  leave(deviceId: string, groupId: string) {
    this.db.prepare('DELETE FROM device_groups WHERE device_id=? AND group_id=?').run(deviceId,groupId);
    this.db.prepare('UPDATE devices SET group_id=? WHERE id=? AND group_id=?').run(this.list(deviceId)[0]?.groupId ?? '',deviceId,groupId);
  }
  common(a: string,b: string,preferred?: string): string | undefined {
    const rows=this.db.prepare(`SELECT a.group_id FROM device_groups a JOIN device_groups b ON a.group_id=b.group_id
      WHERE a.device_id=? AND b.device_id=? ORDER BY a.joined,a.group_id`).all(a,b) as Row[];
    return rows.find(row=>row.group_id===preferred)?.group_id ?? rows[0]?.group_id;
  }
  peers(deviceId: string): Row[] {
    // DISTINCT is essential: sharing several groups must not multiply cards,
    // broadcasts, probes or transfers. Different devices with one name stay distinct.
    return this.db.prepare(`SELECT DISTINCT d.* FROM devices d JOIN device_groups theirs ON theirs.device_id=d.id
      JOIN device_groups mine ON mine.group_id=theirs.group_id WHERE mine.device_id=? AND d.revoked=0 ORDER BY d.created,d.id`).all(deviceId) as Row[];
  }
  members(groupId: string): Row[] {
    return this.db.prepare('SELECT d.* FROM devices d JOIN device_groups m ON m.device_id=d.id WHERE m.group_id=? AND d.revoked=0').all(groupId) as Row[];
  }
}
