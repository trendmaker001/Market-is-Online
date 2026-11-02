-- Enum changes must commit before the new value is used by subsequent migrations.
alter type public.bonus_method add value if not exists 'team_manager';
