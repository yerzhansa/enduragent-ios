from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[1]
proof_root = root / 'apps/ios/EnduragentUITests'
feature_root = root / '.claude/skills/verify-ios/features'
classes = {}
methods = {}
errors = []
for path in sorted(proof_root.glob('*.swift')):
    source = path.read_text()
    declarations = list(re.finditer(r'\bclass\s+(\w+)\s*:\s*XCTestCase\b', source))
    for index, declaration in enumerate(declarations):
        name = declaration.group(1)
        if name in classes:
            errors.append(f'duplicate class {name}')
        classes[name] = path.relative_to(root).as_posix()
        end = declarations[index + 1].start() if index + 1 < len(declarations) else len(source)
        methods[name] = set(re.findall(r'\bfunc\s+(test\w+)\s*\(', source[declaration.end():end]))

feature_files = sorted(feature_root.glob('*.md'))
references = {}
selected_methods = set()
expected_sections = [
    'Sub-features',
    'How to get to it (user POV)',
    'Driving it with sim.mjs and XCUITest',
    'Gotchas',
]
for path in feature_files:
    content = path.read_text()
    references[path.name] = set(re.findall(r'\b[A-Z][A-Za-z0-9]*(?:Proof|Probe)\b', content))
    if path.name != 'README.md':
        sections = re.findall(r'^## (.+)$', content, re.MULTILINE)
        if sections != expected_sections:
            errors.append(f'{path.name}: section contract differs')
    for name, method in re.findall(r'\b([A-Z][A-Za-z0-9]*(?:Proof|Probe))/(test\w+)\b', content):
        selected_methods.add(f'{name}/{method}')
        if method not in methods.get(name, set()):
            errors.append(f'{path.name}: missing method {name}/{method}')

all_references = set().union(*references.values())
feature_references = set().union(*(names for path, names in references.items() if path != 'README.md'))
unknown = sorted(all_references - classes.keys())
unmapped = sorted(classes.keys() - feature_references)
if unknown:
    errors.append('unknown references: ' + ', '.join(unknown))
if unmapped:
    errors.append('unmapped classes: ' + ', '.join(unmapped))

lines = [
    'Feature map proof cross-check',
    f'Feature files checked: {len(feature_files)}',
    f'XCTestCase classes found: {len(classes)}',
    f'Unique proof/probe classes named: {len(all_references)}',
    f'Explicit class/method references checked: {len(selected_methods)}',
]
for name, names in references.items():
    lines.append(f'{name}: {len(names)} classes')
lines += [
    'Unknown proof/probe references: ' + (', '.join(unknown) if unknown else 'none'),
    'Unmapped XCTestCase classes: ' + (', '.join(unmapped) if unmapped else 'none'),
    'Missing selected methods: ' + str(sum('missing method' in error for error in errors)),
    'Feature section contracts: ' + ('PASS' if not any('section contract' in error for error in errors) else 'FAIL'),
]
for error in errors:
    lines.append('ERROR ' + error)
lines.append('Result: ' + ('FAIL' if errors else 'PASS'))
sys.stdout.write('\n'.join(lines) + '\n')
sys.exit(1 if errors else 0)
