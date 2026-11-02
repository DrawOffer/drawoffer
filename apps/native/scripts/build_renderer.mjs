// 把 renderer/entry.ts 打成一个自包含的离线 HTML，再分别复制进 Mac 与 Windows 客户端的资源目录。
// 复用 apps/web 已安装的 esbuild，不引入新依赖：node apps/native/scripts/build_renderer.mjs
import { createRequire } from "node:module";
import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const nativeRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const appsRoot = resolve(nativeRoot, "..");
const require = createRequire(resolve(appsRoot, "web/package.json"));
const { build } = require("esbuild");

const result = await build({
  entryPoints: [resolve(nativeRoot, "renderer/entry.ts")],
  bundle: true,
  write: false,
  format: "iife",
  target: ["safari17", "chrome120"],
  minify: true,
  // Web 源码里的 `?raw` 样式按文本读入，头像按 data URL 内联，保证纸面零网络请求
  plugins: [{
    name: "raw-query",
    setup(pluginBuild) {
      pluginBuild.onResolve({ filter: /\?raw$/ }, (args) => ({
        path: resolve(args.resolveDir, args.path.replace(/\?raw$/, "")),
        namespace: "raw",
      }));
      pluginBuild.onLoad({ filter: /.*/, namespace: "raw" }, async (args) => ({
        contents: await readFile(args.path, "utf8"),
        loader: "text",
      }));
    },
  }],
  loader: { ".png": "dataurl", ".jpg": "dataurl" },
  logLevel: "warning",
});

const script = result.outputFiles[0].text.replace(/<\/script/giu, "<\\/script");
const html = `<!doctype html>
<html lang="zh-CN" data-drawoffer-native-renderer>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:; script-src 'unsafe-inline'">
<title>DrawOffer Paper</title>
</head>
<body><div id="paper-root"></div><script>${script}</script></body>
</html>
`;

const outFile = resolve(nativeRoot, "renderer/dist/paper.html");
mkdirSync(dirname(outFile), { recursive: true });
writeFileSync(outFile, html);

const targets = [
  resolve(appsRoot, "mac/Sources/DrawOfferRender/Resources/paper.html"),
  resolve(appsRoot, "windows/src/DrawOffer.App/Assets/Renderer/paper.html"),
];
for (const target of targets) {
  mkdirSync(dirname(target), { recursive: true });
  copyFileSync(outFile, target);
}
console.log(`paper.html ${(html.length / 1024).toFixed(0)} KiB -> ${targets.length} clients`);

// The native shell uses the exact Web brand asset; regenerate with every paper build.
for (const directory of [
  resolve(appsRoot, 'mac/Sources/DrawOfferApp/Resources/Branding'),
  resolve(appsRoot, 'windows/src/DrawOffer.App/Assets/Branding'),
]) {
  mkdirSync(directory, { recursive: true });
  copyFileSync(resolve(appsRoot, 'web/src/assets/drawoffer-wordmark.png'), resolve(directory, 'wordmark.png'));
}

for (const directory of [resolve(appsRoot, 'mac/Sources/DrawOfferApp/Resources/Home'), resolve(appsRoot, 'windows/src/DrawOffer.App/Assets/Home')]) {
  mkdirSync(directory, { recursive: true });
  for (const filename of ['content.json', 'firstResume.png', 'target.png', 'plugin.png'])
    copyFileSync(resolve(nativeRoot, 'shared/home', filename), resolve(directory, filename));
}

// 可编辑纸面：挂载 Web 同一套 TipTap 编辑器与选区工具栏，样式、字体、图标全部内联。
// 页面由原生 drawoffer-paper:// scheme 加载，纸面图片与上传经该 scheme 由原生带凭据转发。
const webSrc = resolve(appsRoot, "web/src");
const editorResult = await build({
  entryPoints: [resolve(nativeRoot, "renderer/editor.tsx")],
  bundle: true,
  write: false,
  outdir: resolve(nativeRoot, "renderer/dist/editor"),
  format: "iife",
  target: ["safari17", "chrome120"],
  minify: true,
  jsx: "automatic",
  nodePaths: [resolve(appsRoot, "web/node_modules")],
  alias: { "@": webSrc },
  define: {
    "process.env.NODE_ENV": '"production"',
    "import.meta.env.DEV": "false",
    "import.meta.env.PROD": "true",
    "import.meta.env.MODE": '"production"',
    "import.meta.env.BASE_URL": '"/"',
    "import.meta.env": '{"DEV":false,"PROD":true,"MODE":"production","BASE_URL":"/"}',
  },
  plugins: [{
    name: "raw-query",
    setup(pluginBuild) {
      pluginBuild.onResolve({ filter: /\?raw$/ }, (args) => ({
        path: resolve(args.resolveDir, args.path.replace(/\?raw$/, "")),
        namespace: "raw",
      }));
      pluginBuild.onLoad({ filter: /.*/, namespace: "raw" }, async (args) => ({
        contents: await readFile(args.path, "utf8"),
        loader: "text",
      }));
    },
  }],
  loader: {
    ".png": "dataurl", ".jpg": "dataurl", ".jpeg": "dataurl", ".svg": "dataurl", ".webp": "dataurl",
    ".woff2": "dataurl", ".woff": "dataurl", ".ttf": "dataurl", ".otf": "dataurl",
  },
  logLevel: "warning",
});
const editorScript = editorResult.outputFiles.find((file) => file.path.endsWith(".js")).text.replace(/<\/script/giu, "<\\/script");
const editorStyle = (editorResult.outputFiles.find((file) => file.path.endsWith(".css"))?.text ?? "").replace(/<\/style/giu, "<\\/style");
const editorHtml = `<!doctype html>
<html lang="zh-CN" data-drawoffer-native-editor data-ui-theme="light">
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: blob: drawoffer-paper:; font-src data:; connect-src drawoffer-paper:; script-src 'unsafe-inline'">
<title>DrawOffer Editor</title>
<style>${editorStyle}</style>
<style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}#paper-root{height:100%}</style>
</head>
<body><div id="paper-root"></div><script>${editorScript}</script></body>
</html>
`;
const editorOut = resolve(nativeRoot, "renderer/dist/editor.html");
writeFileSync(editorOut, editorHtml);
const editorTarget = resolve(appsRoot, "mac/Sources/DrawOfferRender/Resources/editor.html");
copyFileSync(editorOut, editorTarget);
// 模板示例头像：纸面里写的是站内 /templates/... 地址，由原生 scheme 从随包资源读出
const templateTarget = resolve(appsRoot, "mac/Sources/DrawOfferRender/Resources/templates");
mkdirSync(templateTarget, { recursive: true });
for (const filename of ["avatar-administrative.png", "avatar-administrative.svg", "avatar-campus.png", "avatar-campus.svg", "avatar-cat.jpg", "avatar-civic.png", "avatar-civic.svg", "avatar-creative.png", "avatar-creative.svg"])
  copyFileSync(resolve(appsRoot, "web/public/templates", filename), resolve(templateTarget, filename));
console.log(`editor.html ${(editorHtml.length / 1024).toFixed(0)} KiB -> mac`);
