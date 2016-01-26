-- This function returns the table that is the configuration for this client's
-- DeflectorNet. We make it a function, instead of a straight varaible, so we
-- can load HashablePosition before this happens. The table returned by this
-- function should have the following entries:
--   name: the name of this lua block's DeflectorNet client.
--   blocks: a table mapping HashablePositions to either true or string. If
--       true, then the component at this position is an incoming channel and
--       we're going to read from it. If a string, then this client will take
--       control of that component and use it to send messages as a channel with
--       the specified string name.
-- NOTE: the function name has an _underscore_ in it! This is so that you can
-- place this function declaration up with your own code, above where the
-- DeflectorNet object is defined.
function DeflectorNet_get_init_args()
   return {
	  name = "left",
	  blocks = {
		 [HashablePosition(-2, 1, 3)] = "l1", -- left
		 [HashablePosition(-3, 1, 4)] = "l2", -- left
		 [HashablePosition(2, 1, 4)] = true, -- right
		 [HashablePosition(3, 1, 4)] = true, -- right
	  },
   }
end

last_sent_message = -1
function Update(I)
   -- DeflectorNet.list_blocks(I)
   -- I:Log("foo")
   DeflectorNet.update{I=I}
   
   repeat
   	  local message = DeflectorNet.receive_message{}
   	  if not message then break end
   	  I:Log(string.format("Received message of type %s on channel '%s':\n%s",
   						  message.mtype,
   						  message.cname,
   						  message.message))
   until false

   if I:GetTimeSinceSpawn() > last_sent_message + 2 then
   	  DeflectorNet.queue_message{
   		 message = "TESTING LEFT!",
   		 mtype = DeflectorNet.MessageTypes.string,
   		 channel = "l1",
   	  }
   	  last_sent_message = I:GetTimeSinceSpawn()
   end
end
