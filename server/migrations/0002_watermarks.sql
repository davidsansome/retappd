-- Poll state is now two watermarks (ms epoch, as text): `marker` = newest activity already handled
-- (or baselined), `friend_marker` = newest friend request handled. Unread counts are no longer stored.
ALTER TABLE users ADD COLUMN friend_marker TEXT;
ALTER TABLE users DROP COLUMN last_counts;
