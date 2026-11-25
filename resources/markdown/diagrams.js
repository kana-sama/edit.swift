import mermaid from 'mermaid';

let nextID = 0;

export async function render(root) {
    const dark = matchMedia('(prefers-color-scheme: dark)').matches;
    mermaid.initialize({startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'neutral',
        maxTextSize: 50000, maxEdges: 500, suppressErrorRendering: true});
    for (const element of root.querySelectorAll('[data-mermaid]')) {
        try {
            const {svg} = await mermaid.render(`edit-mermaid-${++nextID}`, element.textContent);
            if (element.isConnected) {
                const diagram = document.createElement('div');
                diagram.className = 'diagram';
                diagram.innerHTML = svg;
                element.closest('pre').replaceChildren(diagram);
            }
        } catch {
            element.classList.add('invalid-diagram');
        }
    }
}
