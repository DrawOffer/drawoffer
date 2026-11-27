// 纸面检查用的模板样本：运行时由 seed_templates.py 从 upstream 后端种子读出并用后端布局编译器算 layout_plan。
// 也可以把 seed_templates.py 的输出存成文件，用 DRAWOFFER_TEMPLATE_SEEDS 指向它（例如在没有 uv 的机器上）。
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

export function loadSeedTemplates(root) {
  if (process.env.DRAWOFFER_TEMPLATE_SEEDS) return JSON.parse(readFileSync(process.env.DRAWOFFER_TEMPLATE_SEEDS, 'utf8'));
  try {
    const output = execFileSync('uv', ['run', '-q', '--no-project', '--with', 'pydantic[email]>=2.10,<3', 'python', '-I',
      resolve(root, 'apps/native/scripts/seed_templates.py'), '--validation'], { maxBuffer: 64 * 1024 * 1024, stdio: ['ignore', 'pipe', 'inherit'] });
    return JSON.parse(output);
  } catch (error) {
    throw new Error('无法从后端种子读取模板：需要 uv 和已初始化的 upstream 子模块（git submodule update --init upstream），'
      + '或先运行 apps/native/scripts/seed_templates.py --validation 并用 DRAWOFFER_TEMPLATE_SEEDS 指向其输出。\n' + error.message);
  }
}
