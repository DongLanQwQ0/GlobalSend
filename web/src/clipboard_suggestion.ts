export type ClipboardSuggestionKind = 'image' | 'text';
export interface ClipboardSuggestionAccess {
  permissions?: {query(value: {name: PermissionName}): Promise<{state: PermissionState}>};
  clipboard?: {read?: () => Promise<readonly {types: readonly string[]}[]>};
}

/** Automatic suggestions never open a permission prompt or load image bytes. */
export async function clipboardSuggestion(access: ClipboardSuggestionAccess): Promise<ClipboardSuggestionKind | null> {
  if (!access.permissions || !access.clipboard?.read) return null;
  try {
    const permission = await access.permissions.query({name: 'clipboard-read' as PermissionName});
    if (permission.state !== 'granted') return null;
    const items = await access.clipboard.read();
    if (items.some(item => item.types.some(type => type.startsWith('image/')))) return 'image';
    return items.some(item => item.types.includes('text/plain') || item.types.includes('text/html')) ? 'text' : null;
  } catch {
    // Safari may not implement this permission; the explicit paste action stays available.
    return null;
  }
}
