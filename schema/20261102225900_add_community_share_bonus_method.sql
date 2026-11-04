-- Enum additions must commit before later constraints/functions use the value.
alter type public.bonus_method add value if not exists 'community_share';
