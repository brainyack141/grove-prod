begin;

-- Plant-care instructions are deliberately separate from sensitive access
-- details. This note is visible on the token-scoped sitter care sheet.
alter table app.sitting_invites
    add column if not exists owner_notes text;

commit;
