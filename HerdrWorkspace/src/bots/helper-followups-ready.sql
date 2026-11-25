WITH pending AS (
  SELECT f.task,f.instruction,f.bot,h.name,j.state,j.launch_key,
    (SELECT min(t.id) FROM journal t WHERE t.kind='task' AND t.core_id=j.core_id
     AND t.address=j.address AND t.created_ms=j.created_ms AND t.state!='not_sent' AND t.id>f.task) AS next_task
  FROM helper_followups f JOIN helpers h ON h.launch=f.launch JOIN journal j ON j.id=h.launch
  WHERE f.cancelled=0 AND f.outbox IS NULL AND j.core_id=?1
) SELECT p.task,p.instruction,p.bot,p.name,substr(r.text,1,2000)
  FROM pending p LEFT JOIN journal r ON r.id=(SELECT min(id) FROM journal
   WHERE reply_for=p.launch_key AND kind='reply' AND trim(text)!='' AND id>p.task AND (p.next_task IS NULL OR id<p.next_task))
  WHERE r.id IS NOT NULL OR p.next_task IS NOT NULL OR p.state IN ('not_sent','start_not_observed')
    OR p.task IN (SELECT value FROM json_each(?2))
  ORDER BY p.task LIMIT 50;
