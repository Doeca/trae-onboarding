# Inputs: info, rows, tasks. IDs must already be JSON strings upstream.
def integer: type == "number" and floor == .;
. as $input | .info.AccountQuotaSummary.Full as $q |
if ([$q.TotalQuota,$q.OccupiedCount,$q.ActiveCount] | all(integer)) and
   (0 <= $q.ActiveCount and $q.ActiveCount <= $q.OccupiedCount and $q.OccupiedCount <= $q.TotalQuota)
then . else error("full_capacity_unknown") end |
if (.rows | all(.UserInfo.Email | type == "string" and length > 0)) and
   (.rows | all(.UserInfo | (.UserID|type=="string") and (if .AccountType==1 then has("JoiningTime") else true end)))
then . else error("member_shape_unknown") end |
[.rows[].UserInfo.Email|ascii_downcase] as $known |
([.rows[].UserInfo | select(.AccountType==1 and (.JoiningTime==0 or .JoiningTime==null)) | .Email|ascii_downcase] +
 [.tasks[] | select(.phase!="COMPLETE") | .email|ascii_downcase | select(. as $email | $known|index($email)|not)] | unique | length) as $pending |
([.rows[].UserInfo | select(.AccountType==1 and .JoiningTime!=0 and .JoiningTime!=null) | .UserID] | unique | length) as $joined |
([$q.OccupiedCount,$joined]|max) as $reserved |
{total:$q.TotalQuota, occupied:$q.OccupiedCount, active:$q.ActiveCount,pending:$pending,reserved_occupied:$reserved,
 available:([0,($q.TotalQuota-$reserved-$pending)]|max)}
