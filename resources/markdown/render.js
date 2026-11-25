import {unified} from 'unified';
import remarkParse from 'remark-parse';
import remarkGfm from 'remark-gfm';
import remarkMath from 'remark-math';
import remarkRehype from 'remark-rehype';
import rehypeRaw from 'rehype-raw';
import rehypeSanitize, {defaultSchema} from 'rehype-sanitize';
import rehypeStringify from 'rehype-stringify';
import Slugger from 'github-slugger';
import {nameToEmoji} from 'gemoji';

const parser = unified().use(remarkParse).use(remarkGfm).use(remarkMath);
const schema = {
    ...defaultSchema,
    clobber: [],
    protocols: {href: ['http', 'https', 'mailto', 'file'], src: ['http', 'https', 'file']},
    tagNames: [...defaultSchema.tagNames, 'figure', 'figcaption', 'caption', 'col', 'colgroup', 'tfoot', 'ruby', 'rt', 'rp'],
    strip: ['script', 'style', 'iframe', 'object', 'embed', 'form', 'template'],
};
const renderer = unified().use(remarkRehype, {allowDangerousHtml: true}).use(rehypeRaw)
    .use(rehypeSanitize, schema).use(rehypeStringify);

function walk(node, callback, parent) {
    callback(node, parent);
    for (const child of node.children ?? []) walk(child, callback, node);
}

function textOf(node) {
    if (node.type === 'text' || node.type === 'inlineCode') return node.value;
    if (node.type === 'image') return node.alt ?? '';
    return (node.children ?? []).map(textOf).join('');
}

function emoji(text) {
    return text.replace(/:([\w+-]+):/g, (match, name) => Object.hasOwn(nameToEmoji, name) ? nameToEmoji[name] : match);
}

const alerts = {
    NOTE: ['Note', 'ℹ'], TIP: ['Tip', '✦'], IMPORTANT: ['Important', '‼'],
    WARNING: ['Warning', '⚠'], CAUTION: ['Caution', '⛔'],
};

export function render(source, includeHTML) {
    const tree = parser.parse(source);
    const slugger = new Slugger();
    const definitions = new Map();
    const noteDefinitions = new Map();
    const noteReferences = new Map();
    const anchors = new Map();
    const tasks = new Map();
    const callouts = new Map();
    const links = [];
    const code = [];
    const at = node => node.position?.start.offset;

    walk(tree, (node, parent) => {
        const start = at(node);
        if (node.type === 'text') node.value = emoji(node.value);
        if (node.type === 'definition' && !definitions.has(node.identifier)) definitions.set(node.identifier, node.url);
        if (node.type === 'footnoteDefinition') noteDefinitions.set(node.identifier, start);
        if (node.type === 'footnoteReference') {
            const references = noteReferences.get(node.identifier) ?? [];
            references.push(start);
            noteReferences.set(node.identifier, references);
        }
        if (node.type === 'listItem' && typeof node.checked === 'boolean') {
            const mark = /^(?:[-+*]|\d+[.)])[ \t]+\[([ xX])\]/.exec(source.slice(start));
            if (mark) tasks.set(start, start + mark[0].length - 2);
        }
        if (node.type === 'blockquote' && parent.type === 'root') {
            const first = node.children[0]?.children?.[0];
            const marker = first?.type === 'text' && /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](?:\n|$)/.exec(first.value);
            if (marker) {
                callouts.set(start, marker[1]);
                first.value = first.value.slice(marker[0].length);
            }
        }
        if (node.type === 'math' || node.type === 'inlineMath') {
            if (node.type === 'inlineMath' && node.value.startsWith('`') && node.value.endsWith('`')) {
                node.value = node.value.slice(1, -1);
            }
            node.data = {hName: node.type === 'math' ? 'pre' : 'code',
                hProperties: {className: ['language-math']}, hChildren: [{type: 'text', value: node.value}]};
        }
    });

    walk(tree, node => {
        const start = at(node);
        const end = node.position?.end.offset;
        if (node.type === 'heading') {
            const id = slugger.slug(textOf(node));
            node.data = {hProperties: {id}};
            anchors.set(id, start);
        }
        if (node.type === 'link' || node.type === 'linkReference' || node.type === 'definition') {
            const target = node.url ?? definitions.get(node.identifier);
            if (target) links.push({start, end, target});
        }
        if (node.type === 'footnoteReference' && noteDefinitions.has(node.identifier)) {
            links.push({start, end, destination: noteDefinitions.get(node.identifier), note: node.identifier});
        }
        if (node.type === 'footnoteDefinition' && noteReferences.has(node.identifier)) {
            const labelEnd = source.indexOf(']:', start);
            if (labelEnd >= start) links.push({start, end: labelEnd + 1, references: noteReferences.get(node.identifier), note: node.identifier});
        }
    });

    const hast = renderer.runSync(tree);
    const disclosures = new Map();
    const parents = new WeakMap();
    const images = [];
    walk(hast, (node, parent) => {
        if (node.type !== 'element') return;
        parents.set(node, parent);
        const properties = node.properties;
        const start = at(node);
        const tag = node.tagName;
        if (start !== undefined && ['p', 'li', 'pre', 'blockquote', 'table', 'details', 'hr', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6'].includes(tag)) {
            properties.dataOffset = String(start);
        }
        if (typeof properties.id === 'string' && start !== undefined && !anchors.has(properties.id)) anchors.set(properties.id, start);
        if (tag === 'a' && typeof properties.name === 'string' && start !== undefined) {
            properties.id ??= properties.name;
            if (!anchors.has(properties.name)) anchors.set(properties.name, start);
        }
        if (tag === 'a' && typeof properties.href === 'string') {
            properties.dataTarget = properties.href;
            properties.href = '#';
        }
        if (tag === 'source') delete properties.srcSet;
        if (tag === 'img') {
            if (typeof properties.src === 'string') {
                properties.dataImage = String(images.length);
                images.push(properties.src);
            }
            delete properties.src;
            delete properties.srcSet;
        }
        if (tag === 'details') {
            const label = textOf(node.children.find(child => child.tagName === 'summary') ?? {children: []});
            const count = disclosures.get(label) ?? 0;
            disclosures.set(label, count + 1);
            properties.dataDisclosure = `${label}\u001f${count}`;
        }
        if (tag === 'input') {
            const item = parent.tagName === 'p' ? parents.get(parent) : parent;
            const task = item?.tagName === 'li' ? tasks.get(at(item)) : undefined;
            if (task !== undefined) {
                properties.dataTask = String(task);
                tasks.delete(at(item));
            }
        }
        if (tag === 'blockquote' && callouts.has(start)) {
            const kind = callouts.get(start);
            const [label, icon] = alerts[kind];
            properties.className = ['alert', kind.toLowerCase()];
            node.children.unshift({type: 'element', tagName: 'p', properties: {className: ['alert-title']},
                children: [{type: 'text', value: `${icon}  ${label}`}]});
        }
        if ((tag === 'pre' || tag === 'code') && properties.className?.includes('language-math')) {
            properties.dataMath = tag === 'pre' || parent.tagName === 'pre' ? 'display' : 'inline';
        } else if (tag === 'code' && parent.tagName === 'pre') {
            const language = properties.className?.find(name => name.startsWith('language-'))?.slice(9);
            if (language === 'mermaid') {
                properties.dataMermaid = '';
            } else if (language) {
                properties.dataCode = String(code.length);
                code.push({language, text: textOf(node)});
            }
        }
    });

    return JSON.stringify({
        html: includeHTML ? renderer.stringify(hast) : '',
        anchors: Object.fromEntries(anchors), links, images, code,
    });
}
