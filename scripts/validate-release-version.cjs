const { execFileSync } = require('node:child_process');
const { appendFileSync } = require('node:fs');

function validateVersion(input, tags) {
    const pattern = /^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$/;
    const match = pattern.exec(input);
    if (!match) throw new Error('Next version must be a stable version such as 1.5.0 or v1.5.0.');
    const parts = match.slice(1).map(BigInt);
    for (const tag of tags) {
        const existing = pattern.exec(tag);
        if (!existing) continue;
        const previous = existing.slice(1).map(BigInt);
        const difference = parts.findIndex((part, index) => part !== previous[index]);
        if (difference === -1 || parts[difference] < previous[difference]) {
            throw new Error(`Next version must be greater than existing tag ${tag}.`);
        }
    }
    return `v${match.slice(1).join('.')}`;
}

if (require.main === module) {
    if (process.env.GITHUB_REF !== 'refs/heads/main') {
        throw new Error('Explicit stable releases must be run from main.');
    }
    const tags = execFileSync('git', ['tag', '--list'], { encoding: 'utf8' }).trim().split('\n');
    const tag = validateVersion(process.env.NEXT_VERSION || '', tags);
    appendFileSync(process.env.GITHUB_OUTPUT, `tag=${tag}\n`);
}

module.exports = { validateVersion };
