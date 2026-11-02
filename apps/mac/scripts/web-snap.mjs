// Local parity checks only: signs the fictional Dev test account into the Web app and prints the
// accessibility snapshot of a route, after an optional list of steps.
// usage: node apps/mac/scripts/web-snap.mjs <path> [steps.json]
//   steps: [{"eval": "<js expression>"} | {"boxes": true} | {"click": "<accessible name>"} | {"fill": "<name>", "text": "..."} | {"press": "Enter"} | {"wait": ms} | {"snap": "<label>"} | {"png": "<file>"}]
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");
const { chromium } = createRequire(resolve(root, "apps/web/package.json"))("playwright-core");
const origin = process.env.DRAWOFFER_API_ORIGIN ?? "http://127.0.0.1:5175";
const email = process.env.DRAWOFFER_TEST_EMAIL ?? "mac-parity-test@example.com";
const password = process.env.DRAWOFFER_OFFLINE ? "" : process.env.DRAWOFFER_TEST_PASSWORD ?? readFileSync(resolve(root, ".runtime/test-password"), "utf8").trim();
const [path = "/assistant", stepsFile] = process.argv.slice(2);
const steps = stepsFile ? JSON.parse(readFileSync(stepsFile, "utf8")) : [];

const browser = await chromium.launch({ executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", headless: true });
const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, locale: "zh-CN" });
const page = await context.newPage();
if (process.env.DRAWOFFER_OFFLINE) { page.on("pageerror", (error) => console.log("pageerror", error.message)); page.on("console", (m) => m.type() === "error" && console.log("console", m.text())); page.on("requestfinished", async (r) => process.env.DRAWOFFER_OFFLINE_LOG && r.url().includes("/api/mock") && console.log("req", r.url(), (await r.response())?.status())); }
// DRAWOFFER_OFFLINE=1：后端或中间件连不上时只看排版——登录态换成虚构用户，其余 /api 请求一律 404（先注册，替身路由后注册的优先）。
if (process.env.DRAWOFFER_OFFLINE) {
  await page.route((url) => url.pathname.startsWith("/api/"), (route) => {
    const url = new URL(route.request().url());
    if (url.pathname === "/api/auth/me") return route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ user: { id: "1", email: "fictional@example.com", display_name: "示例用户", role: "user" } }) });
    if (process.env.DRAWOFFER_OFFLINE_LOG) console.log("offline 404", route.request().method(), url.pathname);
    return route.fulfill({ status: 404, contentType: "application/json", body: JSON.stringify({ error: { code: "NOT_FOUND", message: "offline" } }) });
  });
}
// DRAWOFFER_ROUTE_FIXTURE=<json file>：只读替身，把 GET /api/mock-interviews/{id} 换成虚构场次，看作答页的排版（不创建、不调用 AI）。
if (process.env.DRAWOFFER_ROUTE_FIXTURE) {
  const fixture = readFileSync(process.env.DRAWOFFER_ROUTE_FIXTURE, "utf8");
  await page.route(/\/api\/mock-interviews\/[0-9a-f-]{36}$/, (route) => route.request().method() === "GET"
    ? route.fulfill({ status: 200, contentType: "application/json", body: fixture }) : route.abort());
}
if (!process.env.DRAWOFFER_OFFLINE) {
  const login = await page.request.post(`${origin}/api/auth/login`, { data: { email, password } });
  if (!login.ok()) throw new Error(`login failed ${login.status()}`);
}
await page.goto(origin + path, { waitUntil: "networkidle" });
await page.waitForTimeout(1500);
const target = (name) => page.getByRole("button", { name, exact: true }).or(page.getByRole("link", { name, exact: true }))
  .or(page.getByText(name, { exact: true })).first();
for (const step of steps) {
  if (step.click) await target(step.click).click();
  else if (step.fill) await page.getByRole("textbox", { name: step.fill }).or(page.getByPlaceholder(step.fill)).first().fill(step.text ?? "");
  else if (step.press) await page.keyboard.press(step.press);
  else if (step.eval) console.log(`---- eval\n` + JSON.stringify(await page.evaluate(step.eval)));
  else if (step.boxes) console.log(`---- boxes\n` + (await page.evaluate(() => {
    // Visible, named controls and text leaves with their CSS-pixel boxes, for geometry checks against the Mac AX tree.
    const out = [];
    // With a dialog open, only report the dialog (the Mac sheet is its own window).
    const scope = [...document.querySelectorAll('[role="dialog"], dialog[open]')].pop() ?? document;
    for (const el of scope.querySelectorAll("button, a, input, textarea, [contenteditable=true], h1, h2, h3, p, strong, span, label")) {
      const r = el.getBoundingClientRect();
      if (r.width < 2 || r.height < 2 || r.bottom < 0 || r.top > innerHeight) continue;
      const control = el.matches("button, a, input, textarea, [contenteditable=true]");
      // Text inside a control is reported once, as the control (the Mac AX tree does the same).
      if (!control && el.parentElement?.closest("button, a")) continue;
      const name = (el.getAttribute("aria-label") || (control || !el.children.length ? el.innerText ?? el.textContent : "") || el.getAttribute("placeholder") || "").trim().replace(/\s+/g, " ");
      if (!name) continue;
      const cs = getComputedStyle(el);
      out.push(`${el.tagName.toLowerCase()} ${name.slice(0, 40)} @${Math.round(r.x)},${Math.round(r.y)} ${Math.round(r.width)}x${Math.round(r.height)} ${cs.fontSize}/${cs.fontWeight} ${cs.color}`);
    }
    return out.join("\n");
  })));
  else if (step.png) await page.screenshot({ path: step.png });
  else if (step.snap) console.log(`---- ${step.snap}\n` + await page.locator("body").ariaSnapshot());
  await page.waitForTimeout(step.wait ?? 1200);
}
if (!steps.some((step) => step.snap)) console.log(await page.locator("body").ariaSnapshot());
await browser.close();
