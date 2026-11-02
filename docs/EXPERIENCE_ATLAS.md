# 功能与入口图谱

直接用浏览器打开：

**`F:\Codes\Java\GlobalSend\web\public\experience\index.html`**

这是可离线打开的单文件评审网页，不连接设备、不读取剪贴板、不改变客户端设置。正式功能基线为1.0.89+114，建议入口与已实现入口分别标明。网页文件放在Web的public目录，后续正常Web构建会带入`experience/`；本轮没有为评审页升级运行客户端或部署服务。

## 从模块分工开始讨论

1. 先看主界面、Android悬浮暂存坞、Windows接收窗口的职责和交接。
2. 切换Windows、Android、iOS、iPadOS、Web，点布局中的区域查看功能说明。
3. 在“功能清单”搜索、分类，或筛选本平台可用能力；可展开五平台并排对照。
4. 对照使用路径与编排建议，再确认哪些入口需要迁移。
5. 最后查看待验收项，区分实现、检查和真实系统结果。

模块定位的文字依据见 [模块定位](MODULE_ROLES.md)。现有状态定义沿用 [组件与状态命名](COMPONENTS.md)，不把建议、远程引用、本地副本、自动槽位混称为“推送”。

## 修改与生成

内容在`docs/experience/catalog.mjs`，结构、样式、交互分别在同目录的`index.template.html`、`style.css`、`app.js`。图标复用`web/src/icons.ts`，不添加图标字体、CDN或其它依赖。

在项目根目录运行：

```sh
node scripts/build-experience-atlas.mjs
node web/tool/accept_experience_atlas.mjs
```

第一条生成单文件，检查功能ID、平台、关联功能和引用文档是否存在。第二条使用既有的`artifacts/browser-profile/edge`串行运行浏览器检查，保留登录，不新建配置。检查结果和JPEG截图集中放在`artifacts/tmp/experience-atlas/`；临时HTTP服务和本次启动的浏览器正常关闭。它不操作真实Windows应用或手机。

生成文件可直接双击打开，也可由现有Web静态服务以`/app/experience/`提供。不得仅因文件已生成，就宣称公网已部署或客户端布局已修改。
