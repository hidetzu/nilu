import { createHash } from 'node:crypto';

export const sha256 = content => createHash('sha256').update(content).digest('hex');

// A fence's role is the word that starts with `nilu` (`nilu`, `nilu-cli`,
// `nilu-c`, ...), wherever it stands, so that a fence can begin with the
// language GitHub highlights (```lua nilu, ```sh nilu-cli). Otherwise the role
// is the first word (output, stderr, text, ...).
export function fenceTag(info) {
  const words = info.trim().split(/\s+/).filter(Boolean);
  return words.find(word => word.startsWith('nilu')) ?? words[0] ?? '';
}

export function markdownShape(text) {
  const blocks = [];
  const headings = [];
  let opened;
  for (const line of text.split('\n')) {
    if (opened) {
      const close = /^\s{0,3}(`+|~+)\s*$/.exec(line)?.[1];
      if (close?.[0] === opened.marker[0] && close.length >= opened.marker.length) {
        blocks.push({ tag: opened.tag, body: opened.lines.join('\n') });
        opened = undefined;
      } else opened.lines.push(line);
      continue;
    }
    const fence = /^\s{0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence) {
      opened = { marker: fence[1], tag: fenceTag(fence[2]), lines: [] };
      continue;
    }
    const heading = /^(#{1,6})\s+/.exec(line);
    if (heading) headings.push(heading[1].length);
  }
  if (opened) throw new Error('a fenced block is not closed');
  return { blocks, headings };
}

export function cCode(text) {
  return text.replace(/"(?:\\[\s\S]|[^"\\])*"|'(?:\\[\s\S]|[^'\\])*'|\/\/[^\n]*|\/\*[\s\S]*?\*\//g,
    token => token.startsWith('/') ? ' ' : token);
}
