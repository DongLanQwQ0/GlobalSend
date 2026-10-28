import { Api } from '../src/api';
import { RtcProbeMonitor } from '../src/rtc_probe';

let monitor:RtcProbeMonitor|undefined;
let created=0,closed=0;
const Original=window.RTCPeerConnection;
window.RTCPeerConnection=class extends Original {
  private counted=false;
  constructor(config?:RTCConfiguration) {
    if(config?.iceServers?.length)throw new Error('Idle probe configured an external ICE service');
    super(config);created++;
  }
  override close(){if(!this.counted){this.counted=true;closed++;}super.close();}
};
Object.assign(window,{fixture:{
  async configure(session:{deviceToken:string;device:{deviceId:string}},peers:string[],parallel=false) {
    await monitor?.dispose();
    const api=new Api(location.origin,session as never);
    monitor=new RtcProbeMonitor({api,deviceId:session.device.deviceId,parallel,reportAddresses:parallel,changed:()=>{}});
    monitor.setOnlinePeers(peers);
    await monitor.setForeground(true);
  },
  async refresh(){await monitor?.changed();},
  async foreground(value:boolean){await monitor?.setForeground(value);},
  peers(values:string[]){monitor?.setOnlinePeers(values);},
  state(){return {created,closed,results:monitor?.results ?? []};},
  async close(){await monitor?.dispose();},
}});
