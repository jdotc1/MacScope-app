# MacScope design tokens

Generated from the pinned Lumen registry and `MacScope/DesignSystem/Lumen/MacScopePack.swift` by `Scripts/design/export_tokens.sh`. Do not edit by hand.

**Tier:** semantic roles are defined by every complete theme; component roles default to the role shown. **Theme:** editor roles come from the editor theme (Settings ▸ Themes ▸ Editor theme), window roles from the window theme.

[Surfaces](#surfaces) · [Text and Lines](#text-and-lines) · [Accent](#accent) · [Status and Evidence](#status-and-evidence) · [Syntax](#syntax) · [Debugger](#debugger) · [Window Chrome](#window-chrome) · [Listing](#listing) · [Object Kinds](#object-kinds) · [Graph](#graph) · [Debugger and Shell Decks](#debugger-and-shell-decks) · [Terminal](#terminal)

## Surfaces

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `bg.window` | semantic |  | window | #ECEEF2 | #0D0F13 | #040817 | #FFFFFF | #000000 |
| `bg.sidebar` | semantic |  | window | #F6F6F8 | #1C1F26 | #0A1128 | #FFFFFF | #000000 |
| `bg.canvas` | semantic |  | editor | #FFFFFF | #16181E | #080F24 | #FFFFFF | #000000 |
| `bg.gutter` | semantic |  | editor | #F7F8FA | #14161B | #070D20 | #FFFFFF | #000000 |
| `bg.elevated` | semantic |  | window | #FFFFFF | #23262F | #121B38 | #FFFFFF | #121212 |
| `bg.inset` | semantic |  | window | #E4E6EB | #21242C | #0D1530 | #F2F2F2 | #1A1A1A |
| `bg.hover` | semantic |  | window | #E9EBF0 | #252934 | #16213F | #E6E6E6 | #262626 |
| `bg.selected` | semantic |  | window | #E4DFFF | #2F2A57 | #2B1A66 | #D6CCFF | #2B2470 |
| `bg.selectedInactive` | semantic |  | window | #E2E0E9 | #2D2B40 | #1F2250 | #D9D9D9 | #333333 |
| `code.currentLine` | component | `accent.default at 10% over bg.canvas` | editor | #F4F2FF | #1E2030 | #1A0F45 | #EFEAFF | #1A1A2E |

## Text and Lines

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `fg.primary` | semantic |  | window | #1B1E26 | #DDE3EC | #F2F5FF | #000000 | #FFFFFF |
| `fg.secondary` | semantic |  | window | #4A5162 | #ADB7C5 | #B2B8CC | #1F1F1F | #E6E6E6 |
| `fg.tertiary` | semantic |  | window | #5C6476 | #959FAF | #8C94AD | #555555 | #B0B0B0 |
| `fg.disabled` | semantic |  | window | #979DA9 | #5A6270 | #535B78 | #6E6E6E | #8A8A8A |
| `fg.onAccent` | semantic |  | window | #FFFFFF | #111318 | #060B1B | #FFFFFF | #000000 |
| `fg.link` | semantic |  | window | #5443C9 | #A99BFF | #C9A8FF | #3A1FB8 | #C9BDFF |
| `border.subtle` | semantic |  | window | #E4E6EB | #2C3039 | #1C2644 | #8C8C8C | #8A8A8A |
| `border.default` | semantic |  | window | #DADADD | #333748 | #283456 | #4D4D4D | #BDBDBD |
| `border.strong` | semantic |  | window | #B4B9C4 | #4A4F63 | #2E3B63 | #000000 | #FFFFFF |
| `border.focus` | semantic |  | window | #6757D0 | #8B7CF6 | #A06BFF | #3A1FB8 | #C9BDFF |

## Accent

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `accent.default` | semantic |  | window | #6757D0 | #8B7CF6 | #A06BFF | #4A2FD0 | #B8A8FF |
| `accent.subtle` | semantic |  | window | #F5F3FF | #262245 | #21153F | #E6E0FF | #2A2250 |
| `accent.soft` | semantic |  | window | #B0A2FF | #B0A2FF | #C9A8FF | #7B66E8 | #D6CCFF |

## Status and Evidence

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `status.success` | semantic |  | window | #1E7F46 | #4CC38A | #5FD68F | #0B6B2E | #7CFF9E |
| `status.warning` | semantic |  | window | #935600 | #F2B45A | #FFD321 | #7A4500 | #FFD28A |
| `status.danger` | semantic |  | window | #C4283F | #F0607A | #FF5468 | #B00020 | #FF8A9E |
| `status.info` | semantic |  | window | #2966B8 | #7DA8F5 | #3AA2FF | #0A4DA8 | #9CC4FF |
| `status.neutral` | semantic |  | window | #4A5162 | #A3ADBB | #B2B8CC | #1F1F1F | #E6E6E6 |
| `status.successBackground` | semantic |  | window | #EDF5F0 | #1F332F | #19352A | #D8E7DE | #142919 |
| `status.warningBackground` | semantic |  | window | #FBF0D4 | #393128 | #3A2F1A | #EAE1D6 | #292216 |
| `status.dangerBackground` | semantic |  | window | #F7E1E4 | #39242D | #33171B | #F2D6DB | #291619 |
| `status.infoBackground` | semantic |  | window | #DDE7F4 | #262F40 | #102747 | #D8E3F1 | #191F29 |
| `status.neutralBackground` | semantic |  | window | #D9DBDF | #373A44 | #232A3F | #DBDBDB | #2E2E2E |
| `evidence.proven` | semantic |  | window | #1E7F46 | #4CC38A | #75FB4C | #0B6B2E | #7CFF9E |
| `evidence.inferred` | semantic |  | window | #935600 | #F2B872 | #FFD321 | #7A4500 | #FFD28A |
| `evidence.unknown` | semantic |  | window | #4A5162 | #A3ADBB | #8A92AB | #3D3D3D | #C8C8C8 |
| `evidence.missing` | semantic |  | window | #C4283F | #F0607A | #FF3D6E | #B00020 | #FF8A9E |

## Syntax

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `syntax.mnemonicBranch` | semantic |  | editor | #B3345E | #E885A3 | #FF5C8A | #9E1045 | #FF9EBB |
| `syntax.mnemonicArithmetic` | semantic |  | editor | #2663B5 | #7DA8F5 | #3AA2FF | #0A4DA8 | #9CC4FF |
| `syntax.mnemonicMemory` | semantic |  | editor | #00725C | #61C7AB | #00F0FF | #0B6B55 | #7FF0D6 |
| `syntax.mnemonicGeneral` | semantic |  | editor | #6657AD | #BAA1F2 | #C58BFF | #4A2FD0 | #DCC6FF |
| `syntax.register` | semantic |  | editor | #8B5A00 | #E6B066 | #FFB45C | #7A4500 | #FFD28A |
| `syntax.immediate` | semantic |  | editor | #006F77 | #5EBAC4 | #FFE45C | #0B5F66 | #8AF4FF |
| `syntax.address` | semantic |  | editor | #5E4FB8 | #AB96FA | #C58BFF | #4A2FD0 | #DCC6FF |
| `syntax.modifier` | semantic |  | editor | #636372 | #999EB2 | #8C94AD | #3D3D3D | #C8C8C8 |
| `syntax.punctuation` | semantic |  | editor | #5C6476 | #969FAE | #8C94AD | #00505A | #7FF0D6 |
| `syntax.operator` | semantic |  | editor | #9A4D00 | #FFB86B | #FFB45C | #5B2BB0 | #DCC6FF |
| `syntax.comment` | semantic |  | editor | #6B7385 | #808A9A | #737DA0 | #4D4D4D | #C8C8C8 |
| `syntax.string` | semantic |  | editor | #8A5A00 | #E8C170 | #75FB4C | #6B4500 | #FFE08A |
| `syntax.keyword` | semantic |  | editor | #A0308A | #F28FD0 | #E532AD | #8A106E | #FFB0E6 |
| `syntax.type` | semantic |  | editor | #0E7C8C | #6FD3E0 | #5CE1E6 | #0A4DA8 | #9CC4FF |
| `syntax.function` | semantic |  | editor | #2F5FB3 | #8DB4F7 | #8AB4FF | #0A4DA8 | #9CC4FF |
| `syntax.variable` | semantic |  | editor | #1B1E26 | #DDE3EC | #F2F5FF | #000000 | #FFFFFF |
| `syntax.number` | semantic |  | editor | #127880 | #5EBAC4 | #FFE45C | #7A4500 | #FFD28A |

## Debugger

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `debug.breakpoint` | semantic |  | editor | #D0343F | #FF6B6B | #FF3D6E | #B00020 | #FF8A9E |
| `debug.programCounter` | semantic |  | editor | #8A6200 | #FFD24A | #FFD321 | #7A5A00 | #FFE08A |
| `debug.patched` | semantic |  | editor | #A9480F | #F59E5B | #F29C38 | #9A3A00 | #FFB27A |

## Window Chrome

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `sidebar.background` | component | `bg.sidebar` | window | #F6F6F8 | #1C1F26 | #0A1128 | #FFFFFF | #000000 |
| `sidebar.rowSelected` | component | `bg.selected` | window | #E4DFFF | #2F2A57 | #2B1A66 | #D6CCFF | #2B2470 |
| `sidebar.rowHover` | component | `bg.hover` | window | #E9EBF0 | #252934 | #16213F | #E6E6E6 | #262626 |
| `toolbar.background` | component | `bg.sidebar` | window | #F6F6F8 | #1C1F26 | #0A1128 | #FFFFFF | #000000 |
| `tab.activeFill` | component | `bg.canvas` | window | #FFFFFF | #16181E | #080F24 | #F0F0F0 | #1A1A1A |
| `tab.accentBar` | component | `accent.default` | window | #6757D0 | #8B7CF6 | #A06BFF | #4A2FD0 | #B8A8FF |
| `inspector.background` | component | `bg.sidebar` | window | #F6F6F8 | #1C1F26 | #0A1128 | #FFFFFF | #000000 |
| `statusbar.background` | component | `bg.gutter` | editor | #F7F8FA | #14161B | #070D20 | #FFFFFF | #000000 |

## Listing

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `listing.selection` | component | `bg.selected` | editor | #E4DFFF | #2F2A57 | #2B1A66 | #D6CCFF | #2B2470 |
| `listing.currentLine` | component | `code.currentLine` | editor | #F4F2FF | #1E2030 | #1A0F45 | #EFEAFF | #1A1A2E |
| `listing.alternateRow` | component | `bg.hover at 35% over bg.canvas` | editor | #F7F8FA | #1B1E26 | #0D152D | #F6F6F6 | #0D0D0D |
| `listing.programCounterRow` | component | `debug.programCounter at 16% over bg.canvas` | editor | #ECE6D6 | #3B3625 | #302E24 | #EAE5D6 | #292416 |
| `listing.patchedRow` | component | `debug.patched at 18% over bg.canvas` | editor | #F0DED4 | #3E3029 | #322828 | #EDDCD1 | #2E2016 |
| `listing.secondaryText` | component | `fg.tertiary` | editor | #5C6476 | #959FAF | #8C94AD | #555555 | #B0B0B0 |

## Object Kinds

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `kind.function` | component | `syntax.function` | window | #0064C3 | #7AB4FE | #86BAFE | #004B96 | #A8CEFF |
| `kind.symbol` | component | `syntax.address` | window | #7B57B9 | #C4A9FF | #C9B2FF | #613C9C | #D9CBFE |
| `kind.import` | component | `syntax.keyword` | window | #A03F81 | #ED92CB | #FF8ED7 | #822266 | #FEB2E1 |
| `kind.segment` | component | `syntax.mnemonicArithmetic` | window | #5B6578 | #9AA4B6 | #A2ABC6 | #3F4654 | #CFCFCF |
| `kind.section` | component | `syntax.type` | window | #077783 | #15CBDF | #12D2E7 | #005B65 | #5AE3F7 |
| `kind.string` | component | `syntax.string` | window | #906F02 | #E4BC53 | #F5BF0D | #715700 | #FCD679 |
| `kind.type` | component | `syntax.mnemonicGeneral` | window | #067650 | #52C794 | #07D493 | #00593B | #78E0AF |
| `kind.image` | component | `accent.default` | window | #9F5102 | #FC984C | #FFA15C | #7B3D01 | #FEBE92 |
| `kind.security` | component | `status.success` | window | #577D03 | #A4C973 | #A3D45A | #426003 | #BFE293 |
| `kind.debug` | component | `debug.breakpoint` | window | #AE0326 | #FF7475 | #FF8180 | #83021A | #FFA39F |

## Graph

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `graph.node.background` | component | `bg.elevated` | editor | #FFFFFF | #23262F | #121B38 | #FFFFFF | #121212 |
| `graph.lane.background` | component | `bg.inset` | editor | #F5F6F8 | #121419 | #060B1D | #F7F7F7 | #101010 |

## Debugger and Shell Decks

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `deck.background` | component | `bg.inset` | window | #F6F8F9 | #13151A | #060C1E | #F8F8F8 | #0D0D0D |
| `deck.rowBackground` | component | `bg.elevated` | window | #FBFCFC | #1B1E24 | #0C142B | #FCFCFC | #101010 |

## Terminal

| Token | Tier | Falls back to | Theme | Scope light | Scope dark | Midnight | Contrast light | Contrast dark |
|---|---|---|---|---|---|---|---|---|
| `terminal.foreground` | component | `fg.primary` | editor | #1B1E26 | #DDE3EC | #F2F5FF | #000000 | #FFFFFF |
| `terminal.background` | component | `bg.canvas` | editor | #FFFFFF | #16181E | #080F24 | #FFFFFF | #000000 |
| `terminal.cursor` | component | `accent.default` | editor | #6757D0 | #8B7CF6 | #A06BFF | #4A2FD0 | #B8A8FF |
| `terminal.ansi.black` | component | `bg.inset` | editor | #1B1E26 | #2A2E3A | #121B38 | #000000 | #3A3A3A |
| `terminal.ansi.red` | component | `status.danger` | editor | #C4283F | #F0607A | #FF3D6E | #B00020 | #FF8A9E |
| `terminal.ansi.green` | component | `status.success` | editor | #1E7F46 | #4CC38A | #75FB4C | #0B6B2E | #7CFF9E |
| `terminal.ansi.yellow` | component | `status.warning` | editor | #935600 | #F2B45A | #FFD321 | #7A4500 | #FFD28A |
| `terminal.ansi.blue` | component | `status.info` | editor | #2966B8 | #7DA8F5 | #3AA2FF | #0A4DA8 | #9CC4FF |
| `terminal.ansi.magenta` | component | `syntax.keyword` | editor | #A0308A | #F28FD0 | #E532AD | #8A106E | #FFB0E6 |
| `terminal.ansi.cyan` | component | `syntax.type` | editor | #0E7C8C | #6FD3E0 | #00F0FF | #0B5F66 | #8AF4FF |
| `terminal.ansi.white` | component | `fg.secondary` | editor | #8A90A0 | #C3CBD8 | #B2B8CC | #6E6E6E | #E6E6E6 |
| `terminal.ansi.brightBlack` | component | `fg.tertiary` | editor | #646C7E | #5A6274 | #4C5470 | #3D3D3D | #8A8A8A |
| `terminal.ansi.brightRed` | component | `status.danger` | editor | #D0343F | #FF8A9E | #FF5C8A | #9E1045 | #FFB3C1 |
| `terminal.ansi.brightGreen` | component | `status.success` | editor | #12856E | #7FE0AE | #A6FF8A | #0B6B55 | #B0FFC4 |
| `terminal.ansi.brightYellow` | component | `status.warning` | editor | #8A6200 | #FFD28A | #FFE45C | #6B4500 | #FFE6B8 |
| `terminal.ansi.brightBlue` | component | `status.info` | editor | #5443C9 | #A8C6FF | #8AB4FF | #3A1FB8 | #C4DCFF |
| `terminal.ansi.brightMagenta` | component | `syntax.keyword` | editor | #BD3D66 | #FFB0E6 | #FF6FD0 | #4A2FD0 | #FFD0F0 |
| `terminal.ansi.brightCyan` | component | `syntax.type` | editor | #127880 | #9CEAF2 | #5CE1E6 | #00505A | #C0F9FF |
| `terminal.ansi.brightWhite` | component | `fg.primary` | editor | #C3C7D0 | #F2F5FA | #F2F5FF | #8C8C8C | #FFFFFF |
