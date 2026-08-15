/**
 * Local type shims so this package typechecks and builds without installing
 * @deepseek-ai/cordis or @deepseek-ai/schemastery (peerDependencies only).
 * These are not a reimplementation of those packages.
 */

declare module "@deepseek-ai/cordis" {
  export interface Context {
    [key: string]: unknown;
    on(event: string, handler: (...args: unknown[]) => void): unknown;
    effect(factory: () => void | (() => void) | Promise<void | (() => void)>): unknown;
    sessions?: unknown;
    agents?: unknown;
  }
}

declare module "@deepseek-ai/schemastery" {
  interface SchemaNode {
    default(value: unknown): SchemaNode;
    required(): SchemaNode;
  }

  interface SchemaFactory {
    object(fields: Record<string, SchemaNode>): unknown;
    string(): SchemaNode;
    number(): SchemaNode;
    boolean(): SchemaNode;
  }

  const Schema: SchemaFactory;
  export default Schema;
}
