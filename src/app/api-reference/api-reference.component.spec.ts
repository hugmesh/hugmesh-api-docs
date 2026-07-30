import { ComponentFixture, TestBed } from '@angular/core/testing';
import { ApiReferenceComponent } from './api-reference.component';

/**
 * ApiReferenceComponent renders the read-only contract tables. These specs pin
 * the parameter/response extraction, schema-name resolution, and the accessible
 * table markup (th[scope=col] + <caption class="sr">).
 */
describe('ApiReferenceComponent', () => {
  let fixture: ComponentFixture<ApiReferenceComponent>;
  let component: ApiReferenceComponent;

  const spec = {
    tags: [{ name: 'Things', description: 'Thing management' }],
  };
  const active = {
    tag: 'Things',
    method: 'post',
    path: '/bff/admin/things',
    op: {
      summary: 'Create a thing',
      parameters: [{ name: 'dryRun', in: 'query', required: true, schema: { type: 'boolean' } }],
      requestBody: { content: { 'application/json': { schema: { $ref: '#/components/schemas/Thing' } } } },
      responses: {
        '201': { description: 'created', content: { 'application/json': {} } },
        '400': { description: 'bad request' },
      },
    },
  };

  beforeEach(async () => {
    await TestBed.configureTestingModule({
      imports: [ApiReferenceComponent],
    }).compileComponents();
    fixture = TestBed.createComponent(ApiReferenceComponent);
    component = fixture.componentInstance;
  });

  it('shows the empty state when no operation is selected', () => {
    fixture.detectChanges();
    const el: HTMLElement = fixture.nativeElement;
    expect(el.querySelector('.empty h2')!.textContent).toContain('Pick an operation');
  });

  it('resolves the tag blurb from the tag description', () => {
    component.spec = spec;
    component.active = active;
    expect(component.tagBlurb()).toBe('Thing management');
  });

  it('extracts parameters, request-body content types, and responses', () => {
    component.spec = spec;
    component.active = active;
    expect(component.parameters().length).toBe(1);
    expect(component.requestBodyEntries()[0][0]).toBe('application/json');
    expect(component.responseEntries().map((e) => e[0])).toEqual(['201', '400']);
  });

  it('resolves a $ref schema to its component name', () => {
    expect(component.schemaName({ $ref: '#/components/schemas/Thing' })).toBe('Thing');
    expect(component.typeOf({ schema: { type: 'string', format: 'uuid' } })).toBe('string(uuid)');
  });

  describe('accessibility', () => {
    beforeEach(() => {
      component.spec = spec;
      component.active = active;
      fixture.detectChanges();
    });

    it('renders parameter + response tables with th[scope=col]', () => {
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelectorAll('table thead th[scope="col"]').length).toBeGreaterThanOrEqual(6);
    });

    it('gives each table an sr-only <caption>', () => {
      const el: HTMLElement = fixture.nativeElement;
      const captions = el.querySelectorAll('table caption.sr');
      expect(captions.length).toBeGreaterThanOrEqual(2);
      captions.forEach((c) => expect(c.textContent!.trim().length).toBeGreaterThan(0));
    });

    it('flags a required parameter with a visible pill', () => {
      const el: HTMLElement = fixture.nativeElement;
      expect(el.querySelector('.pill-required')!.textContent).toContain('required');
    });

    it('shows a read-only help hint pointing at the Try-it-out tab', () => {
      const el: HTMLElement = fixture.nativeElement;
      const hint = el.querySelector('.hint')!;
      expect(hint).withContext('read-only hint exists').not.toBeNull();
      expect(hint.textContent).toContain('Try-it-out');
    });

    it('hides the decorative crumb separator from screen readers', () => {
      const el: HTMLElement = fixture.nativeElement;
      const sep = el.querySelector('.crumb [aria-hidden="true"]')!;
      expect(sep).withContext('decorative separator is aria-hidden').not.toBeNull();
      expect(sep.textContent!.trim()).toBe('·');
    });
  });
});
