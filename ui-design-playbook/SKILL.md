---
name: ui-design-playbook
description: Use when designing or redesigning screens, components, flows, or page sections with weak visual hierarchy, inconsistent spacing scales, bland design-system drift, or overreliance on framework defaults such as SwiftUI forms and lists.
---

# UI Design Playbook

## Overview

Turn UI work into a sequence of design decisions instead of a pile of decorations. Start from the feature and the content, create hierarchy before styling, and use constrained systems for type, spacing, color, and depth so the result feels intentional.

This playbook is derived from the core ideas in `Refactoring UI`, adapted for practical frontend and product UI work.

## When to Use

Use when:
- designing a new screen, flow, component, landing page, dashboard, or settings page
- redesigning an interface that feels generic, cramped, muddy, or visually flat
- reviewing UI work and diagnosing weak hierarchy, arbitrary spacing, or inconsistent styling
- working inside an opinionated environment like SwiftUI, where semantics and defaults are useful but should not define the visual hierarchy on their own

Do not use when:
- the task is purely visual asset production with no interface structure to design
- you are only implementing an existing, approved design system without changing layout or hierarchy

## Workflow

1. Define the feature.
   - Identify the user task, primary action, and most important content.
   - Start with the feature, not the page shell.

2. Build the hierarchy in grayscale.
   - Decide what is primary, secondary, and tertiary.
   - Use position, contrast, density, weight, and spacing before relying on color.

3. Choose systems, not one-off values.
   - Use a restrained spacing scale, type scale, radius strategy, and shadow strategy.
   - Avoid pixel-by-pixel tweaking when a token or scale can decide for you.

4. Add personality deliberately.
   - Let typography, color, radius, and language create the tone.
   - Pick a clear visual direction instead of defaulting to generic startup UI.

5. Add depth and polish only where they clarify.
   - Use shadows, borders, layering, and background treatment to support grouping, elevation, and focus.
   - Keep decorative moves subordinate to readability and hierarchy.

## During Implementation

- Set type, spacing, color, radius, and shadow tokens before refining components.
- Keep the main task and dominant content obvious in the first viewport.
- Reuse the same small set of surface treatments instead of styling each section from scratch.
- Check the layout in grayscale before trusting accent color.
- On opinionated platforms, customize composition and surfaces before replacing native controls.

## Quick Reference

| Area | Do | Avoid |
|---|---|---|
| Structure | Start from a real feature and its content | Starting with nav bars, sidebars, and generic shells |
| Hierarchy | De-emphasize secondary content so primary content can lead | Solving hierarchy with font size alone |
| Spacing | Start roomy, then remove space deliberately | Filling every available area |
| Layout | Use widths that fit the content | Stretching sections full-width by default |
| Typography | Use a limited type scale and readable line lengths | Using many near-identical font sizes |
| Color | Build grayscale structure first, then add color systems | Using color to compensate for weak hierarchy |
| Depth | Use consistent light logic and restrained elevation | Heavy blur, glossy noise, or random shadows |
| Polish | Prefer subtle backgrounds, accents, and strong empty states | Border-heavy boxes and decorative clutter |

## Core Heuristics

### Structure

- Design around the main task first.
- Let supporting chrome emerge from the feature set.
- Prefer content-driven width over filling the canvas because space exists.

### Hierarchy

- Not every element deserves equal emphasis.
- Use two or three text colors and a small number of font weights.
- Emphasize by de-emphasizing competing elements.
- Separate visual hierarchy from document or component hierarchy.

### Spacing and Layout

- Start with more white space than you think you need, then tighten.
- Use a spacing and sizing scale with visibly different steps.
- Avoid ambiguous spacing; related items should be obviously closer to each other than to unrelated items.
- Grids are tools, not laws.

### Typography

- Use a constrained type scale.
- Choose fonts for the intended tone and reading context.
- Keep line length and line-height readable.
- Use weight, color, casing, and spacing together; do not ask size to do all the work.

### Color

- Think in systems: greys, primary colors, and accents, each with multiple shades.
- Prefer HSL-style thinking so hue, saturation, and lightness can be adjusted intentionally.
- Use reduced contrast, not faded opacity, when softening text on colored surfaces.
- Do not rely on color alone to communicate state or emphasis.

### Depth and Surfaces

- Assume a consistent light source from above.
- Use shadows to communicate elevation, not just decoration.
- Use fewer borders; when contrast is too subtle, a slightly heavier border can work better than a darker one.
- Layer backgrounds and surfaces sparingly so the UI gains depth without noise.

### Images and Finishing Touches

- Make sure text over imagery has reliable contrast.
- Use background decoration to support atmosphere, not steal focus.
- Empty states deserve intentional layout, copy, and action design.

## Working With Environment Primitives

Use platform primitives for semantics, behavior, accessibility, and familiarity. Use design judgment for hierarchy, grouping, spacing, and tone.

- Preserve native structure when it helps: list behavior, form semantics, hit targets, navigation, toggles, focus, accessibility, and dynamic type.
- Override or compose around defaults when the out-of-the-box presentation creates weak hierarchy, muddy grouping, or generic surfaces.
- Treat environment primitives as raw materials, not visual truth.
- Group by user intent, not by whatever buckets the framework exposes first.
- In opinionated systems like SwiftUI, customize mostly at the surface and composition level before replacing controls wholesale.
- Do not replace native controls unless composition-level changes still cannot achieve the product goal.

## Common Mistakes

- starting from a shell instead of a feature
- making everything loud, bold, or equally contrasted
- using too many font sizes, colors, radii, or shadow styles
- filling empty space instead of using it to create order
- relying on framework defaults without checking whether the hierarchy still works
- inventing one-off values instead of extending a system
- using opacity to mute text on colored surfaces until it looks disabled

## Review Checklist

- Is the main task obvious within a few seconds?
- Is the most important content clearly dominant?
- Are spacing and font sizes chosen from systems instead of ad hoc values?
- Does the UI still make sense in grayscale?
- Does color reinforce meaning instead of rescuing the design?
- Do depth, surfaces, and borders clarify grouping and elevation?
- Are platform primitives helping semantics without forcing generic hierarchy?
