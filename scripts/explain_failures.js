#!/usr/bin/env node
/*
 * Prints, for every failed assertion in a newman JSON report: the request,
 * the status, the assertion's own error message, and the actual response
 * body. That is everything needed to decide whether the assertion is wrong
 * or the server is.
 *
 *   node scripts/explain_failures.js newman-reports/collection01-results.json
 *   node scripts/explain_failures.js <report> --full     # untruncated bodies
 */

const fs = require('fs');

const file = process.argv[2];
const full = process.argv.includes('--full');
if (!file) {
    console.error('usage: node scripts/explain_failures.js <newman-json-report> [--full]');
    process.exit(1);
}

const report = JSON.parse(fs.readFileSync(file, 'utf8'));
const executions = (report.run && report.run.executions) || [];

const body = (stream) => {
    if (!stream) return '(no body)';
    try {
        const text = Buffer.from(stream.data || stream).toString('utf8');
        try { return JSON.stringify(JSON.parse(text), null, 2); } catch (_) { return text || '(empty body)'; }
    } catch (_) { return '(unreadable)'; }
};

const clip = (s, n) => (full || s.length <= n) ? s : s.slice(0, n) + `\n... [${s.length - n} more chars, pass --full]`;

let failed = 0, requests = 0;
const seen = new Set();

for (const e of executions) {
    const bad = (e.assertions || []).filter(a => a.error);
    if (!bad.length) continue;

    // The report can list the same execution more than once. Key on the
    // cursor ref so each request is reported exactly once.
    const key = (e.cursor && e.cursor.ref)
        || `${(e.item && e.item.id) || ''}|${bad.map(a => a.assertion).join(',')}`;
    if (seen.has(key)) continue;
    seen.add(key);

    requests++;
    failed += bad.length;

    const u = e.request && e.request.url;
    const url = !u ? '(unknown url)'
        : typeof u === 'string' ? u
        : `${u.protocol || 'https'}://${(u.host || []).join('.')}/${(u.path || []).join('/')}`;

    console.log('='.repeat(78));
    console.log(`ITEM     ${e.item.name}`);
    console.log(`REQUEST  ${(e.request && e.request.method) || '?'} ${url}`);
    console.log(`STATUS   ${e.response ? `${e.response.code} ${e.response.status || ''}` : '(no response)'}`);

    for (const a of bad) {
        console.log(`\n  FAILED  ${a.assertion}`);
        console.log(`  WHY     ${a.error.message}`);
    }

    console.log('\n  ACTUAL RESPONSE BODY:');
    console.log(clip(body(e.response && e.response.stream), 1500).split('\n').map(l => '    ' + l).join('\n'));
    console.log();
}

console.log('='.repeat(78));
console.log(`${failed} failed assertion(s) across ${requests} request(s) in ${file}`);
