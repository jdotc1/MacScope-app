# Codesign DER entitlements fixture

`codesign-entitlements.der` is the unmodified 158-byte output of the installed Apple codesign, generated locally from the adjacent authored plist. It contains true and false Booleans, integer 42, UTF-8 string `fixture é`, ordered array `[second, first]`, and a nested dictionary with count -7, enabled true and label child. No Apple entitlement payload or executable is included.

## Regenerating

Run from a scratch directory outside the repository:

```sh
python3 - <<'PYTHON'
import plistlib
values = {'bool-true': True, 'bool-false': False, 'integer': 42, 'string': 'fixture é',
          'array': ['second', 'first'], 'nested': {'enabled': True, 'label': 'child', 'count': -7}}
open('fixture-entitlements.plist', 'wb').write(plistlib.dumps(values))
PYTHON
cp /usr/bin/true fixture-true && chmod 755 fixture-true
/usr/bin/codesign -s - -f --entitlements fixture-entitlements.plist fixture-true
/usr/bin/codesign -d --entitlements - --der fixture-true > codesign-entitlements.der
```

Copy `fixture-entitlements.plist` and `codesign-entitlements.der` into this directory. The signed executable stays outside the repository.

Observed encoding: `70 81 9b 02 01 01 b0 81 95`; dictionary pairs are `30`, nested dictionary is `b0`, array is `30`, strings/keys are `0c`, Booleans `01 01 ff` / `01 01 00`, integers `02 01 2a` / `02 01 f9`.

Legacy compatibility is justified by Apple's real older signer, which called `der_encode_plist(entDict)` in [Security-59754.120.12 signer.cpp](https://github.com/apple-oss-distributions/Security/blob/Security-59754.120.12/OSX/libsecurity_codesigning/lib/signer.cpp#L903-L943). Its [dictionary encoder](https://github.com/apple-oss-distributions/Security/blob/Security-59754.120.12/OSX/utilities/der_dictionary.c#L152-L234) used SET, while its [array encoder](https://github.com/apple-oss-distributions/Security/blob/Security-59754.120.12/OSX/utilities/der_array.c#L77-L94) used SEQUENCE. The current real fixture is versioned; the separate legacy compatibility vectors are synthetic, based on that producer source.
