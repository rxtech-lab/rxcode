# JSON UI interactions

`ide__show_ui` and mobile `show_ui` share the catalog in `JSONUICatalog` and the native `JSONUIRenderer`. Existing display specs remain valid. The tool description and generated schema advertise all supported components to Claude, Codex, and ACP clients.

## Controls and state

The renderer supports `Button`, `TextField`, `TextEditor`, `Toggle`, `Picker`, and `Slider`. Inputs use a unique `name`, defaulting to their element ID. `value` supplies the initial value. Pickers require nonempty, unique string `options`; sliders require finite bounds, a positive step, and an initial value within bounds. `disabled` disables a control. `required` checks text inputs for non-whitespace content on submission.

Button `action` and alert `confirmAction` use these objects:

| Action | Behavior |
| --- | --- |
| `{"type":"present","target":"editor"}` | Open a presentation by element ID. |
| `{"type":"dismiss"}` | Close the current presentation. |
| `{"type":"set","name":"title","value":"Draft"}` | Update a local input. |
| `{"type":"reset"}` | Restore input defaults. |
| `{"type":"submit"}` | Validate required text inputs and capture current values. |

Submit/reset inside a `Form` apply to that form's descendants. An explicit `target` pointing to a `Form` selects that scope, including from alert confirmation actions. Outside a form, submit/reset apply to all inputs.

State belongs to one renderer instance, remains available when its sheet closes and reopens, and resets when the spec changes or the renderer is recreated. Actions never execute commands, invoke tools, persist values, or send answers to the agent. The show-UI tool returns immediately. Default chat rendering reports local capture in a status overlay. A host can supply `JSONUIRenderer(spec:onSubmit:)` to receive the submitted values; the synchronous callback only acknowledges handoff, not completion of an external operation.

## Presentations

Keep create, update, and delete forms in dedicated `Sheet` or `Dialog` elements. Both use a full-height native navigation sheet on Apple platforms, with a title and Done button. `Alert` and `ConfirmationDialog` use native system presentations with an optional `confirmAction`, `confirmLabel`, and `destructive` flag. Without a confirmation action, they offer an acknowledgment button. `Overlay` provides dismissible status content.

Presentation elements remain hidden until opened. They can be detached from the document root; their child trees still validate. Only one presentation can be active at a time. Close it before opening another. Status updates appear in an overlay, including inside sheets. Mobile button actions, toggle/picker/slider changes provide selection haptics.

The existing top-level `presentation: "dialog"` continues to open the whole tool view in the host's dialog and retain its transcript card. Agents are told to keep views inline (the default) and use `dialog` only when the user explicitly asks for one. It is separate from a `Dialog` element inside a spec.

## Example

Pass this as a `show_ui` tool argument. The editor opens from its button; required-field errors and capture/reset feedback appear as overlays.

```json
{
  "title": "Draft editor",
  "spec": {
    "root": "root",
    "elements": {
      "root": { "type": "Stack", "children": ["open", "confirmReset"] },
      "confirmReset": { "type": "Button", "props": { "label": "Reset draft with confirmation", "action": { "type": "present", "target": "resetAlert" } } },
      "open": { "type": "Button", "props": { "label": "Edit draft", "action": { "type": "present", "target": "editor" } } },
      "editor": { "type": "Sheet", "props": { "title": "Edit draft" }, "children": ["form"] },
      "form": { "type": "Form", "children": ["title", "notes", "enabled", "priority", "progress", "reset", "save"] },
      "title": { "type": "TextField", "props": { "label": "Title", "required": true, "placeholder": "Draft title" } },
      "notes": { "type": "TextEditor", "props": { "label": "Notes" } },
      "enabled": { "type": "Toggle", "props": { "label": "Enabled", "value": true } },
      "priority": { "type": "Picker", "props": { "label": "Priority", "options": ["Low", "Medium", "High"], "value": "Medium" } },
      "progress": { "type": "Slider", "props": { "label": "Progress", "min": 0, "max": 100, "step": 5, "value": 25 } },
      "reset": { "type": "Button", "props": { "label": "Reset", "action": { "type": "reset" } } },
      "save": { "type": "Button", "props": { "label": "Capture draft locally", "action": { "type": "submit" } } },
      "resetAlert": { "type": "Alert", "props": { "title": "Reset draft?", "message": "Restore this form to its default values.", "confirmLabel": "Reset", "destructive": true, "confirmAction": { "type": "reset", "target": "form" } } }
    }
  }
}
```
