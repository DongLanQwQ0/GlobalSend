import type { CopiedFileItem, CopiedFileOffer, CopiedFilePull } from "../../packages/protocol/src/index.ts";

interface Device { id: string; name: string }
interface SourceOffer { offerId: string; sourceDeviceId: string; createdAt: string; items: CopiedFileItem[]; targetDeviceIds: string[] }
interface Connections {
  device: (id: string) => Device | undefined;
  online: (id: string) => boolean;
  commonGroup: (a: string, b: string) => string | undefined;
  send: (id: string, message: unknown) => void;
}
function fail(code: string, message: string, statusCode = 409): never {
  throw Object.assign(new Error(message), { code, statusCode });
}

/** One current clipboard per source installation. Bytes stay on that source. */
export class CopiedFiles {
  private connections: Connections;
  private offers = new Map<string, SourceOffer>();
  private pulls = new Map<string, CopiedFilePull>();
  constructor(connections: Connections) { this.connections = connections; }
  private changed(source: string, targets: string[]) {
    for (const target of new Set(targets)) if (this.connections.commonGroup(source, target))
      this.connections.send(target, { type: "clipboard.files.changed", sourceDeviceId: source });
  }
  publish(source: string, offerId: string, items: CopiedFileItem[], targetDeviceIds: string[]) {
    if (!this.connections.online(source)) fail("DEVICE_OFFLINE", "请先连接中心再共享复制的文件");
    const targets = [...new Set(targetDeviceIds)];
    if (!targets.length) fail("COPIED_FILES_TARGET_REQUIRED", "请先指定目标设备", 400);
    if (targets.some(target => target === source || !this.connections.device(target) || !this.connections.commonGroup(source, target)))
      fail("FORBIDDEN", "目标设备不在共同分组中", 403);
    if (new Set(items.map(item => item.id)).size !== items.length)
      fail("COPIED_FILE_IDS", "复制条目编号重复", 400);
    const previous = this.offers.get(source);
    if (previous?.offerId === offerId) {
      if (JSON.stringify(previous.items) !== JSON.stringify(items) || JSON.stringify(previous.targetDeviceIds) !== JSON.stringify(targets))
        fail("COPIED_FILES_CONFLICT", "该复制批次已用于其他文件");
      return previous;
    }
    this.withdraw(source, false);
    const offer = { offerId, sourceDeviceId: source, createdAt: new Date().toISOString(), items, targetDeviceIds: targets };
    this.offers.set(source, offer);
    this.changed(source, [...(previous?.targetDeviceIds ?? []), ...targets]);
    return offer;
  }
  withdraw(source: string, notify = true) {
    const previous = this.offers.get(source), removed = this.offers.delete(source);
    for (const [key, pull] of this.pulls) if (pull.sourceDeviceId === source) this.pulls.delete(key);
    if (previous && notify) this.changed(source, previous.targetDeviceIds);
    return { withdrawn: removed };
  }
  list(target: string): { offers: CopiedFileOffer[] } {
    const offers: CopiedFileOffer[] = [];
    for (const offer of this.offers.values()) {
      const source = this.connections.device(offer.sourceDeviceId);
      const groupId = this.connections.commonGroup(offer.sourceDeviceId, target);
      if (source && groupId && source.id !== target && offer.targetDeviceIds.includes(target) && this.connections.online(source.id)) {
        const { targetDeviceIds: _, ...visible } = offer;
        offers.push({ ...visible, sourceName: source.name, groupId });
      }
    }
    offers.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
    return { offers };
  }
  request(target: string, source: string, body: { offerId: string; requestId: string; itemIds: string[] }) {
    const key = `${target}/${body.requestId}`;
    const previous = this.pulls.get(key);
    if (previous) {
      if (previous.sourceDeviceId !== source || previous.offerId !== body.offerId || JSON.stringify(previous.itemIds) !== JSON.stringify(body.itemIds))
        fail("COPIED_PULL_CONFLICT", "该拉取编号已用于其他文件");
      if (!this.connections.commonGroup(source, target)) fail("FORBIDDEN", "设备已离开共同分组", 403);
      return previous;
    }
    const offer = this.offers.get(source);
    const groupId = this.connections.commonGroup(source, target);
    if (source === target || !groupId || !this.connections.device(source) || offer && !offer.targetDeviceIds.includes(target))
      fail("FORBIDDEN", "复制来源不在共同分组中", 403);
    if (!offer || offer.offerId !== body.offerId || !this.connections.online(source))
      fail("COPIED_FILES_UNAVAILABLE", "来源已离线或剪贴板内容已更换", 404);
    if (new Set(body.itemIds).size !== body.itemIds.length || body.itemIds.some(id => !offer.items.some(item => item.id === id)))
      fail("COPIED_FILE_UNAVAILABLE", "复制条目已不可用", 404);
    const pull: CopiedFilePull = { ...body, sourceDeviceId: source, targetDeviceId: target, groupId, state: "pending" };
    this.pulls.set(key, pull);
    this.connections.send(source, { type: "clipboard.files.pull", ...pull });
    return pull;
  }
  pending(source: string) {
    return { pulls: [...this.pulls.values()].filter(pull => pull.sourceDeviceId === source && pull.state === "pending" &&
      this.connections.commonGroup(source, pull.targetDeviceId)) };
  }
  status(target: string, requestId: string) {
    const pull = this.pulls.get(`${target}/${requestId}`);
    if (!pull || !this.connections.commonGroup(pull.sourceDeviceId, target))
      fail("COPIED_PULL_UNAVAILABLE", "未找到此文件拉取请求", 404);
    return pull;
  }
  result(source: string, target: string, requestId: string,
      body: { state: "sending" | "sent" | "failed"; error?: string }) {
    const pull = this.status(target, requestId);
    if (pull.sourceDeviceId !== source) fail("FORBIDDEN", "只能处理本机提供的文件", 403);
    if (pull.state === "sent" || pull.state === "failed") return pull;
    pull.state = body.state;
    if (body.state === "failed") pull.error = body.error || "来源未能发送所选文件";
    this.connections.send(target, { type: "clipboard.files.pull.updated", ...pull });
    return pull;
  }
}
