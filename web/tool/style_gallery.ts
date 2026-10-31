// 开发期样式画廊的运行时：只做主题/容器宽度切换与图标水合。
// 刻意不 import main.ts（有注册、订阅等副作用），只复用真实样式表、appearance 与 icons。
import '../src/style.css';
import { appearancePalette } from '../src/appearance';
import type { AccentColor, AppearanceMode } from '../src/appearance';
import { icon } from '../src/icons';

const root = document.documentElement;
const systemDark = window.matchMedia('(prefers-color-scheme: dark)');
const readout = document.getElementById('gallery-appearance-readout');
const widths = [360, 768, 1280];

let mode: AppearanceMode = 'light';
let accent: AccentColor = 'green';
let containerWidth = 1280;

function effectiveMode(): 'light' | 'dark' | 'neutral' {
  if (mode === 'system') return systemDark.matches ? 'dark' : 'light';
  if (mode === 'dark') return 'dark';
  if (mode === 'neutral') return 'neutral';
  return 'light';
}

function paintReadout() {
  if (!readout) return;
  const theme = effectiveMode();
  readout.textContent = 'data-theme=' + theme + (mode === 'system' ? '（跟随系统）' : '') +
    ' · data-accent=' + accent + ' · 容器 ' + containerWidth + 'px';
}

// 与产品一致的路径：palette 变量写到 documentElement 的内联样式，
// 主题/主色落到 dataset.theme / dataset.accent，CSS 层不需要感知画廊。
function applyAppearance() {
  const theme = effectiveMode();
  const dark = theme === 'dark';
  root.dataset.theme = theme;
  root.dataset.themePreference = mode;
  root.dataset.accent = accent;
  root.style.colorScheme = dark ? 'dark' : 'light';
  const palette = appearancePalette({ mode, accent }, systemDark.matches);
  for (const [key, value] of Object.entries(palette)) root.style.setProperty('--' + key, value);
  root.style.setProperty('--soft', 'color-mix(in srgb,var(--green) ' + (dark ? 13 : 8) + '%,var(--surface))');
  document.querySelectorAll<HTMLButtonElement>('[data-appearance-accent]').forEach(button => {
    const value = button.dataset.appearanceAccent as AccentColor;
    button.setAttribute('aria-pressed', String(value === accent));
    button.style.setProperty('--swatch', appearancePalette({ mode, accent: value }, systemDark.matches).green);
  });
  document.querySelectorAll<HTMLButtonElement>('[data-appearance-mode]').forEach(button => {
    button.setAttribute('aria-pressed', String(button.dataset.appearanceMode === mode));
  });
  document.querySelectorAll<HTMLButtonElement>('[data-gallery-theme]').forEach(button => {
    button.setAttribute('aria-pressed', String(button.dataset.galleryTheme === mode));
  });
  paintReadout();
}

function applyWidth() {
  root.style.setProperty('--gallery-width', containerWidth + 'px');
  document.querySelectorAll<HTMLButtonElement>('[data-gallery-width]').forEach(button => {
    button.setAttribute('aria-pressed', String(Number(button.dataset.galleryWidth) === containerWidth));
  });
  paintReadout();
}

// 占位节点被真实 <svg> 就地替换：这样 DOM 与产品一致，
// 产品里 'button svg'、':scope > svg' 这类直接子元素选择器才照常命中。
function hydrateIcons() {
  document.querySelectorAll<HTMLElement>('[data-icon]').forEach(node => {
    const name = node.dataset.icon;
    if (!name) return;
    const template = document.createElement('template');
    template.innerHTML = icon(name);
    const svg = template.content.firstElementChild;
    if (svg) node.replaceWith(svg);
  });
}

document.addEventListener('click', event => {
  const target = event.target instanceof Element ? event.target : null;
  if (!target) return;
  const themeButton = target.closest<HTMLElement>('[data-gallery-theme]');
  if (themeButton?.dataset.galleryTheme) {
    mode = themeButton.dataset.galleryTheme as AppearanceMode;
    applyAppearance();
    return;
  }
  const widthButton = target.closest<HTMLElement>('[data-gallery-width]');
  if (widthButton?.dataset.galleryWidth) {
    const next = Number(widthButton.dataset.galleryWidth);
    if (widths.includes(next)) {
      containerWidth = next;
      applyWidth();
    }
    return;
  }
  const modeButton = target.closest<HTMLElement>('[data-appearance-mode]');
  if (modeButton?.dataset.appearanceMode) {
    mode = modeButton.dataset.appearanceMode as AppearanceMode;
    applyAppearance();
    return;
  }
  const accentButton = target.closest<HTMLElement>('[data-appearance-accent]');
  if (accentButton?.dataset.appearanceAccent) {
    accent = accentButton.dataset.appearanceAccent as AccentColor;
    applyAppearance();
  }
});

// 画廊里的表单只是静态样本：拦掉提交，避免任何请求或页面跳转。
document.addEventListener('submit', event => event.preventDefault());

systemDark.addEventListener('change', () => {
  if (mode === 'system') applyAppearance();
});

hydrateIcons();
applyWidth();
applyAppearance();
