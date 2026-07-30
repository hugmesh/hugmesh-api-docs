/**
 * ApiReferenceComponent — read-only reference rendered from the OpenAPI spec.
 * Shown on the "Reference" tab of DocsShellComponent.
 *
 * Layout: a tag blurb (from x-hugmesh.blurb or the tag description), then the
 * operation summary, long description, parameters table, request-body table,
 * responses table, and any committed sample request/response/event. No
 * interactive controls.
 *
 * Standalone — consumable directly via federation as './ApiReference' if a host
 * wants ONLY the reference view.
 *
 * Adapted from hugmesh.games/frontend/projects/api-docs to the hugmesh UI
 * standard: separate .ts/.html/.scss/.spec.ts, brand --hug-* tokens, accessible
 * tables (th[scope=col] + <caption class="sr">).
 */
import {
  ChangeDetectionStrategy,
  Component,
  Input,
} from '@angular/core';
import { CommonModule } from '@angular/common';
import { OpenApiOperation, OpenApiSpec } from '../docs-shell/docs-shell.component';

/** A single OpenAPI parameter object (`in: path | query | header | cookie`). */
interface OpenApiParameter {
  name?: string;
  in?: string;
  required?: boolean;
  description?: string;
  schema?: { type?: string; format?: string; $ref?: string };
}

/** A single OpenAPI schema object, as used by `typeOf`/`schemaName`. */
interface OpenApiSchema {
  $ref?: string;
  type?: string;
  format?: string;
  properties?: Record<string, unknown>;
}

/** A single OpenAPI media-type map (`content`), e.g. `{ 'application/json': { schema } }`. */
interface OpenApiMediaTypeMap {
  [mediaType: string]: { schema?: OpenApiSchema };
}

/** A single OpenAPI `requestBody` object. */
interface OpenApiRequestBody {
  description?: string;
  required?: boolean;
  content?: OpenApiMediaTypeMap;
}

/** A single OpenAPI response object (one entry of `responses`). */
interface OpenApiResponse {
  description?: string;
  content?: OpenApiMediaTypeMap;
}

/** The `x-hugmesh` vendor-extension object read from an operation. */
interface OpenApiHugMeshExtension {
  longDescription?: string;
  sse?: boolean;
  binaryUpload?: { field: string; description?: string; accept?: string };
  sampleRequest?: unknown;
  sampleResponse?: unknown;
  sampleEvent?: unknown;
  [key: string]: unknown;
}

@Component({
  selector: 'hug-api-docs-api-reference',
  standalone: true,
  imports: [CommonModule],
  changeDetection: ChangeDetectionStrategy.OnPush,
  templateUrl: './api-reference.component.html',
  styleUrl: './api-reference.component.scss',
})
export class ApiReferenceComponent {
  /** The full parsed OpenAPI spec for the currently selected service. */
  @Input() spec: OpenApiSpec | null = null;

  /**
   * The operation being displayed. An `OpenApiOperation` carrying
   * `{ tag, method, path, op }` where `op` is the raw OpenAPI path-item
   * operation object.
   */
  @Input() active: OpenApiOperation | null = null;

  /**
   * Returns the `x-hugmesh` extension object from the active operation, or
   * an empty object when no extension is present. Used by template helpers to
   * read `longDescription`, `sampleRequest`, `sampleResponse`, etc.
   */
  snap(): OpenApiHugMeshExtension {
    return this.active?.op?.['x-hugmesh'] || {};
  }

  /**
   * Returns the extended long-form prose description for the operation from
   * `x-hugmesh.longDescription`, or an empty string when absent.
   */
  longDesc(): string {
    return this.snap().longDescription || '';
  }

  /**
   * Returns the introductory blurb displayed above the operation list for the
   * current tag. Prefers `x-hugmesh.blurb` over the standard OpenAPI tag
   * `description`, falling back to an empty string if neither is set.
   */
  tagBlurb(): string {
    const tag = this.spec?.tags?.find((t) => t.name === this.active?.tag);
    return tag?.['x-hugmesh']?.blurb || tag?.description || '';
  }

  /**
   * Returns all parameter objects (`in: path | query | header | cookie`) from
   * the active operation, or an empty array when none are declared.
   */
  parameters(): OpenApiParameter[] {
    return this.active?.op?.parameters || [];
  }

  /**
   * Returns the `requestBody` object from the active operation, or `undefined`
   * when the operation does not accept a body (e.g. GET).
   */
  requestBody(): OpenApiRequestBody | undefined {
    return this.active?.op?.requestBody;
  }

  /**
   * Returns `[mediaType, mediaTypeObject]` pairs for the request body's
   * `content` map (e.g. `['application/json', {...}]`). Returns an empty array
   * when the operation has no request body.
   */
  requestBodyEntries(): [string, { schema?: OpenApiSchema }][] {
    const rb = this.requestBody();
    return rb?.content ? Object.entries(rb.content) : [];
  }

  /**
   * Returns `[statusCode, responseObject]` pairs for all declared responses
   * on the active operation (e.g. `['200', {...}]`, `['403', {...}]`).
   */
  responseEntries(): [string, OpenApiResponse][] {
    return Object.entries(this.active?.op?.responses || {});
  }

  /**
   * Returns `[mediaType, mediaTypeObject]` pairs for a single response object's
   * `content` map, or an empty array when the response has no content.
   *
   * @param resp - A single OpenAPI response object.
   */
  contentEntries(resp: OpenApiResponse): [string, { schema?: OpenApiSchema }][] {
    return resp?.content ? Object.entries(resp.content) : [];
  }

  /**
   * Returns a human-readable type string for an OpenAPI parameter object by
   * inspecting its `schema` field:
   * - `$ref` → the component name (last segment of the reference path)
   * - `type` (+ optional `format`) → e.g. `"string"` or `"integer(int64)"`
   * - fallback → JSON-serialised schema
   *
   * @param p - An OpenAPI parameter object with an optional `schema` property.
   */
  typeOf(p: OpenApiParameter): string {
    const s = p?.schema;
    if (!s) return '';
    if (s.$ref) return s.$ref.split('/').pop() ?? '';
    if (s.type) return s.type + (s.format ? `(${s.format})` : '');
    return JSON.stringify(s);
  }

  /**
   * Returns a human-readable name for an OpenAPI schema object:
   * - `$ref` → component name (last path segment)
   * - inline object with properties → `"inline object"`
   * - primitive type → the type string
   * - fallback → JSON-serialised schema
   *
   * @param s - An OpenAPI schema object.
   */
  schemaName(s: OpenApiSchema | undefined): string {
    if (!s) return '';
    if (s.$ref) return s.$ref.split('/').pop() ?? '';
    if (s.type === 'object' && s.properties) return 'inline object';
    return s.type || JSON.stringify(s);
  }

  /**
   * Pretty-prints any value for display in a `<pre>` block. String values are
   * returned as-is; everything else is serialised with two-space indentation.
   *
   * @param v - The value to format.
   */
  pretty(v: unknown): string {
    if (typeof v === 'string') return v;
    return JSON.stringify(v, null, 2);
  }
}
