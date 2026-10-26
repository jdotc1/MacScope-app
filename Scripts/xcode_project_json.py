"""Read Apple's JSON project syntax, allowing only its trailing-comma extension."""
from __future__ import annotations

import json
from pathlib import Path

MAX_PROJECT_BYTES = 16 * 1024 * 1024


def loads_project(text: str) -> dict:
    if len(text.encode('utf-8')) > MAX_PROJECT_BYTES:
        raise ValueError('Xcode project exceeds fixed size bound')
    result: list[str] = []
    quoted = escaped = False
    for index, char in enumerate(text):
        if quoted:
            result.append(char)
            if escaped:
                escaped = False
            elif char == '\\':
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
            result.append(char)
        elif char == ',':
            following = index + 1
            while following < len(text) and text[following] in ' \t\r\n':
                following += 1
            previous = index - 1
            while previous >= 0 and text[previous] in ' \t\r\n':
                previous -= 1
            trailing = (following < len(text) and text[following] in '}]'
                        and previous >= 0 and text[previous] not in '[{,:')
            if not trailing:
                result.append(char)
        else:
            result.append(char)

    def unique_pairs(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError(f'duplicate Xcode project key: {key}')
            value[key] = item
        return value

    def invalid_constant(value):
        raise ValueError(f'invalid JSON constant: {value}')

    try:
        value = json.loads(''.join(result), object_pairs_hook=unique_pairs,
                           parse_constant=invalid_constant)
    except RecursionError as error:
        raise ValueError('Xcode project nesting exceeds parser limit') from error
    if not isinstance(value, dict):
        raise ValueError('Xcode project must be an object')
    return value


def read_project(path: Path) -> dict:
    with path.open('rb') as stream:
        payload = stream.read(MAX_PROJECT_BYTES + 1)
    if len(payload) > MAX_PROJECT_BYTES:
        raise ValueError('Xcode project exceeds fixed size bound')
    return loads_project(payload.decode('utf-8'))
