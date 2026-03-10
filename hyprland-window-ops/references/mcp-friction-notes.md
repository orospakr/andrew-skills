# Hyprland MCP Friction Notes

## Common failures

- `Window not found` when using `address:<hex>` without `0x` prefix.
- Dispatch succeeds but windows change before follow-up checks.
- Targeting by title/class can be ambiguous across multiple terminals.

## Reliable practices

- Re-enumerate right before mutation.
- Normalize addresses to `0x...` and dispatch as `address:0x...`.
- Verify final workspace/class/title for each target address.
- Report changed vs already-compliant windows.
