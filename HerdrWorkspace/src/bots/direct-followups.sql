-- A normal direct turn's first reply reaches the app through its live turn.
-- A second reply to the same task can arrive much later, even with the app closed.
SELECT r.id,r.reply_for
FROM journal r
JOIN journal launch ON launch.launch_key=r.reply_for
JOIN journal task ON task.id=(
    SELECT t.id FROM journal t
    WHERE t.core_id=launch.core_id AND t.address=launch.address AND t.created_ms=launch.created_ms
      AND t.kind='task' AND t.state!='not_sent' AND t.id<r.id
    ORDER BY t.id DESC LIMIT 1
)
WHERE r.id>?1 AND r.id<=?2 AND r.kind='reply' AND r.answers_task IS NULL AND trim(r.text)!=''
  AND task.text!='' AND task.thread_reply_token IS NULL
  AND task.id>coalesce((SELECT CAST(value AS INTEGER) FROM bot_state WHERE key='floor:'||r.reply_for),0)
  AND EXISTS (SELECT 1 FROM journal p WHERE p.reply_for=r.reply_for AND p.kind='reply'
                AND p.answers_task IS NULL AND p.id>task.id AND p.id<r.id)
  AND NOT EXISTS (SELECT 1 FROM group_members WHERE launch_key=r.reply_for)
  AND NOT EXISTS (SELECT 1 FROM bot_outbox o WHERE o.task=task.id)
  AND NOT EXISTS (SELECT 1 FROM bot_history h WHERE h.journal=r.id)
ORDER BY r.id;
