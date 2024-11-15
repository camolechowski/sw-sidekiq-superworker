module Sidekiq
  module Superworker
    class SubjobProcessor
      class << self
        def enqueue(subjob)
          Superworker.debug "#{subjob.to_info}: Trying to enqueue"
          # Only enqueue subjobs that aren't running, complete, etc
          return unless subjob.status == 'initialized'
          
          Superworker.debug "#{subjob.to_info}: Enqueueing"
          # If this is a parallel subjob, enqueue all of its children
          if subjob.subworker_class == 'parallel'
            subjob.update_attribute(:status, 'running')

            Superworker.debug "#{subjob.to_info}: Enqueueing parallel children"
            jids = subjob.children.collect do |child|
              enqueue(child)
            end
            jid = jids.first
          elsif subjob.subworker_class == 'batch'
            subjob.update_attribute(:status, 'running')

            Superworker.debug "#{subjob.to_info}: Enqueueing batch children"
            jids = subjob.children.collect do |child|
              child.update_attribute(:status, 'running')
              enqueue(child.children.first)
            end
            jid = jids.first
          else
            klass = "::#{subjob.subworker_class}".constantize

            # If this is a superworker, mark it as complete, which will queue its children or its next subjob
            if klass.respond_to?(:is_a_superworker?) && klass.is_a_superworker?
              complete(subjob)
            # Otherwise, enqueue it in Sidekiq
            else
              # We need to explicitly set the job's JID, so that the ActiveRecord record can be updated before
              # the job fires off. If the job started first, it could finish before the ActiveRecord update
              # transaction completes, causing a race condition when finding the ActiveRecord record in
              # Processor#complete.
              jid = subjob.jid
              subjob.update_attributes(
                status: 'queued'
              )
              enqueue_in_sidekiq(subjob, klass, jid)
            end
          end
          jid
        end

        def enqueue_in_sidekiq(subjob, klass, jid)
          Superworker.debug "#{subjob.to_info}: Enqueueing in Sidekiq"

          # If sidekiq-unique-jobs is being used for this worker, a number of issues arise if the subjob isn't
          # queued, so we'll bypass the unique functionality of the worker while running the subjob.
          is_unique = klass.respond_to?(:sidekiq_options_hash) && !!(klass.sidekiq_options_hash || {})['unique']
          if is_unique
            unique_value = klass.sidekiq_options_hash.delete('unique')
            unique_job_expiration_value = klass.sidekiq_options_hash.delete('unique_job_expiration')
          end

          sidekiq_push(subjob, klass, jid)

          if is_unique
            klass.sidekiq_options_hash['unique'] = unique_value
            klass.sidekiq_options_hash['unique_job_expiration'] = unique_job_expiration_value
          end

          jid
        end

        def complete(subjob)
          Superworker.debug "#{subjob.to_info}: Complete"
          subjob.update_attribute(:status, 'complete')

          # If children are present, enqueue the first one
          children = subjob.children
          if children.present?
            Superworker.debug "#{subjob.to_info}: Enqueueing children"
            enqueue(children.first)
            return
          # Otherwise, set this as having its descendants complete
          else
            descendants_are_complete(subjob)
          end
        end

        def error(subjob, worker, item, exception)
          Superworker.debug "#{subjob.to_info}: Error"
          subjob.update_attribute(:status, 'failed')
          SuperjobProcessor.error(subjob.superjob_id, worker, item, exception)
        end

        protected

        def descendants_are_complete(subjob)
          Superworker.debug "#{subjob.to_info}: Descendants are complete"
          subjob.update_attribute(:descendants_are_complete, true)

          if subjob.subworker_class == 'batch_child' || subjob.subworker_class == 'batch'
            complete(subjob)
          end

          parent = subjob.parent
          is_child_of_parallel = parent && parent.subworker_class == 'parallel'

          # If a parent exists, check whether this subjob's siblings are all complete
          if parent
            siblings_descendants_are_complete = parent.children.all? { |child| child.descendants_are_complete }
            if siblings_descendants_are_complete
              Superworker.debug "#{subjob.to_info}: Parent (#{parent.to_info}) is complete"
              descendants_are_complete(parent)
              if is_child_of_parallel && !Superworker.options[:delete_subjobs_after_superjob_completes]
                parent.update_attribute(:status, 'complete')
              end
            end
          end

          unless is_child_of_parallel
            # If a next subjob is present, enqueue it
            next_subjob = subjob.next
            if next_subjob
              enqueue(next_subjob)
              return
            end

            # If there isn't a parent, then, this is the final subjob of the superjob
            unless parent
              Superworker.debug "#{subjob.to_info}: Superjob is complete"
              SuperjobProcessor.complete(subjob.superjob_id)
            end
          end
        end

        def sidekiq_push(subjob, klass, jid)
          # This is akin to perform_async, but it allows us to explicitly set the JID
          item = sidekiq_item(subjob, klass, jid)
          Sidekiq::Client.push(item)
        end

        def sidekiq_item(subjob, klass, jid)
          item = { 'class' => klass, 'args' => subjob.arg_values, 'jid' => jid }
          if subjob.meta && subjob.meta[:sidekiq]
            item.merge!(subjob.meta[:sidekiq].stringify_keys)
          end
          item
        end
      end
    end
  end
end
