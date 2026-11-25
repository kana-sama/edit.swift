import katex from 'katex';
import 'katex/dist/katex.min.css';

export function render(root) {
    for (const element of root.querySelectorAll('[data-math]')) {
        try {
            const html = katex.renderToString(element.textContent, {
                displayMode: element.dataset.math === 'display', trust: false, maxExpand: 1000, maxSize: 20,
            });
            element.innerHTML = html;
            element.classList.add('equation');
        } catch {
            element.classList.add('invalid-equation');
        }
    }
}
