begin;

-- Account handovers and anonymous links intentionally share the same visible
-- permission, but not the same authority. The assignment needs its own durable
-- bit so bootstrap and the care-action guard can enforce the owner's choice.
alter table app.sitting_assignments
    add column if not exists can_log_care boolean not null default true;

commit;
