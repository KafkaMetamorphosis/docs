#!/bin/bash

  ask() {
    local number="$1" question="$2"
    shift 2
    echo
    echo "$number. $question"
    local i=1
    for option in "$@"; do
      echo "  $i) $option"
      ((i++))
    done
    read -r -p "Choose 1-$((i - 1)): " selection
    echo "Q$number=$selection" >> /tmp/franz-ux-answers.txt
  }

  rm -f /tmp/franz-ux-answers.txt

  ask 1 "What is an Async Channel in the first release?" \
    "One channel creates exactly one Kafka topic." \
    "One channel may create several topics, using a Franz-managed pattern." \
    "A customer explicitly defines the several topics in a channel." \
    "A channel is an abstraction; its Kafka realization is decided by a backend profile."

  ask 2 "What backend scope should the first UX support?" \
    "Kafka only." \
    "Kafka only, but UI language/data model must anticipate other backends." \
    "Kafka and SQS." \
    "Kafka, SQS, RabbitMQ, and Pub/Sub."

  ask 3 "How should customers choose placement?" \
    "Choose from admin-defined placement profiles only." \
    "Choose a profile and a few permitted constraints, such as geography." \
    "Use raw affinity selectors and tolerations themselves." \
    "Admins assign placement; customers cannot choose it."

  echo
  echo "4. How should an application discover and use an Async Channel?"
  echo "  1) Use a Franz SDK/runtime client."
  echo "  2) Receive generated connection configuration/secret."
  echo "  3) Read Kafka bootstrap servers and topic names from Franz."
  echo "  4) Other — type your answer."
  read -r -p "Choose 1-4: " selection
  if [[ "$selection" == "4" ]]; then
    read -r -p "Describe the discovery approach: " custom_answer
    echo "Q4=Other: $custom_answer" >> /tmp/franz-ux-answers.txt
  else
    echo "Q4=$selection" >> /tmp/franz-ux-answers.txt
  fi

  ask 5 "What migration semantics should Franz plan for?" \
    "Only move desired placement; data migration is out of scope." \
    "Create target topic, then remove source topic; no data/offset migration." \
    "Replicate data and migrate consumer offsets with a managed cutover." \
    "Guide an externally-run migration and track its progress."

  ask 6 "How should the 3k partitions-per-broker capacity rule behave?" \
    "Hard block: reject operations that exceed the limit." \
    "Warning with an approval override." \
    "Automatically stop new placement and alert admins before the limit." \
    "Dashboard advisory only; admins act manually."

  ask 7 "What role should Franz play in Kafka upgrades?" \
    "Show upgrade readiness/status only." \
    "Provide a maintenance workflow: drain, upgrade externally, restore." \
    "Orchestrate external infrastructure/upgrade tools." \
    "Perform the full Kafka upgrade natively."

  ask 8 "What access boundary should the initial UX use?" \
    "Roles only: Fleet Admin and Customer." \
    "Team/namespace ownership; customers manage channels only in their team." \
    "Team ownership plus approval workflows for sensitive changes." \
    "Organization-wide multi-tenancy with delegated administrators."

  echo
  echo "Your answers:"
  cat /tmp/franz-ux-answers.txt
