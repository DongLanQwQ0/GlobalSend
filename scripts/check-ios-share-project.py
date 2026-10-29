"""Read-only structural check for the host/Share Extension target contract."""
import pathlib
import plistlib
import re

root=pathlib.Path(__file__).resolve().parents[1]
source=(root/'client/ios/Runner.xcodeproj/project.pbxproj').read_text(encoding='utf-8')
source=re.sub(r'/\*.*?\*/|//[^\n]*','',source,flags=re.S)
tokens=re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z0-9_./$<>+\-]+|[{}()=;,]',source)
index=0
def parse():
 global index
 token=tokens[index];index+=1
 if token=='{':
  result={}
  while tokens[index]!='}':
   key=parse();assert tokens[index]=='=';index+=1;result[key]=parse();assert tokens[index]==';';index+=1
  index+=1;return result
 if token=='(':
  result=[]
  while tokens[index]!=')':
   result.append(parse())
   if tokens[index]==',':index+=1
  index+=1;return result
 return token[1:-1] if token.startswith('"') else token
project=parse();assert index==len(tokens);objects=project['objects']
all_refs=re.findall(r'\b[A-F0-9]{24}\b',source)
assert all(reference in objects for reference in all_refs),'Unresolved PBX reference'
targets={item['name']:item for item in objects.values() if isinstance(item,dict) and item.get('isa')=='PBXNativeTarget'}
main,extension=targets['Runner'],targets['ShareExtension']
assert extension['productType']=='com.apple.product-type.app-extension'
assert any(objects[dep]['target']==next(key for key,value in objects.items() if value is extension) for dep in main['dependencies'])
assert any(objects[phase].get('dstSubfolderSpec')=='13' and any(objects[item]['fileRef']==extension['productReference'] for item in objects[phase]['files']) for phase in main['buildPhases'])
embed=next(phase for phase in main['buildPhases'] if objects[phase].get('dstSubfolderSpec')=='13')
thin=next(phase for phase in main['buildPhases'] if objects[phase].get('name')=='Thin Binary')
assert main['buildPhases'].index(embed)<main['buildPhases'].index(thin),'Embedding must precede the script that reads/processes the host Info.plist'
for target in [main,extension]:
 configs=objects[target['buildConfigurationList']]['buildConfigurations'];assert len(configs)==3
 for config in configs:
  settings=objects[config]['buildSettings'];assert 'CODE_SIGN_ENTITLEMENTS' in settings
  entitlements=plistlib.loads((root/'client/ios'/settings['CODE_SIGN_ENTITLEMENTS']).read_bytes())
  assert entitlements['com.apple.security.application-groups']==['$(GLOBALSEND_APP_GROUP_ID)']
for name in ['Runner/SharedInboxStore.swift','Runner/FileSharing.swift','ShareExtension/ShareViewController.swift']:
 assert (root/'client/ios'/name).is_file()
info=plistlib.loads((root/'client/ios/ShareExtension/Info.plist').read_bytes())
assert info['NSExtension']['NSExtensionPointIdentifier']=='com.apple.share-services'
host_info=plistlib.loads((root/'client/ios/Runner/Info.plist').read_bytes())
assert host_info['FlutterDeepLinkingEnabled'] is False, 'Native sharing owns the URL; Flutter must not interpret it as a page route'
assert any('globalsend' in item.get('CFBundleURLSchemes',[]) for item in host_info['CFBundleURLTypes'])
for name in ['Runner/AppDelegate.swift','Runner/SceneDelegate.swift']:
 assert 'FileSharing.shared.handleURL' in (root/'client/ios'/name).read_text(encoding='utf-8')
assert 'UIApplication.shared' not in (root/'client/ios/ShareExtension/ShareViewController.swift').read_text(encoding='utf-8')
assert 'Flutter' not in (root/'client/ios/ShareExtension/ShareViewController.swift').read_text(encoding='utf-8')
print('Host dependency, extension target/embed, three matching entitlement configurations, sources and plists: OK')
