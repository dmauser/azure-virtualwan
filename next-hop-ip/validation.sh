while true; do
  TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
  RESPONSE=$(curl --max-time 5 -s 10.2.1.4)
  if [ $? -eq 0 ]; then
    echo "[$TIMESTAMP] curl succeeded: $RESPONSE"
  else
    echo "[$TIMESTAMP] curl failed or timed out"
  fi
  sleep 5
done


