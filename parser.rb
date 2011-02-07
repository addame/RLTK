# Author:		Chris Wailes <chris.wailes@gmail.com>
# Project: 	Ruby Language Toolkit
# Date:		2011/01/19
# Description:	This file contains the base class for parsers that use RLTK.

############
# Requires #
############

# Standard Library
require 'pp'

# Ruby Language Toolkit
require 'lexers/ebnf'

#######################
# Classes and Modules #
#######################

module RLTK
	class ParsingError < Exception; end
	
	class Parser
		def Parser.inherited(klass)
			klass.class_exec do
				@rules = Hash.new {|h, k| h[k] = Array.new}
				@proxy = RuleProxy.new(self)
				
				#################
				# Class Methods #
				#################
				
				def self.close_set(set)
					set.each do |rule|
						if (next_token = rule.next_token) and next_token.type == :NONTERM
							set.append(@rules[next_token.value])
						end
					end
					
					return set
				end
				
				def self.explain(explain_file)
					if @rules and @table
						File.open(explain_file, 'w') do |f|
							f.puts("##############" + '#' * self.name.length)
							f.puts("# Rules for #{self.name} #")
							f.puts("##############" + '#' * self.name.length)
							f.puts
							
							#Print the rules.
							@rules.each_key do |sym|
								@rules[sym].each do |rule|
									f.puts("\t#{rule.to_s}")
								end
								
								f.puts
							end
							
							f.puts("Start symbol: #{@start_symbol}")
							f.puts
							
							#Print the parse table.
							f.puts("###############")
							f.puts("# Parse Table #")
							f.puts("###############")
							f.puts
							
							@table.each do |row|
								f.puts("State #{row.id}:")
								
								max = row.set.rules.inject(0) do |max, item|
									if item.symbol.to_s.length > max then item.symbol.to_s.length else max end
								end
								
								row.set.each do |item|
									f.puts("\t#{item.to_s(max, true)}")
								end
								
								f.puts
								f.puts("\t# ACTIONS #")
								
								row.actions.each do |token, actions|
									sym = if token then token[1] else nil end
									
									actions.each do |action|
										f.puts("\tOn #{if sym then sym else 'any' end} #{action}")
									end
								end
								
								f.puts
							end
						end
					else
						File.open(table_file, 'w') {|f| f.puts('Parser.dump called outside of finalize.')}
					end
				end
				
				def self.finalize(explain_file = nil)
					#Create our Transition Table
					@table	= Table.new
					
					#pp @rules.values.flatten
					
					@actions	= @rules.values.flatten.inject([]) {|a, r| a[r.id] = r.action; a}
					
					#Add our starting set to the transition table.
					start_rule = Rule.new(0, :'!start', [Token.new(:DOT), Token.new(:NONTERM, @start_symbol)])
					start_set = self.close_set(Set.new([start_rule]))
					@table.add_state(start_set)
					
					#Build the rest of the transition table.
					@table.each do |row|
						#Transition Sets
						tsets = Hash.new {|h,k| h[k] = Set.new}
						
						#Bin each item in this set into reachable
						#transition sets.
						row.set.each do |rule|
							if (next_token = rule.next_token)
								tsets[[next_token.type, next_token.value]] << rule.copy
							end
						end
						
						#For each transition set:
						# 1) Get transition token
						# 2) Advance dot
						# 3) Close it
						# 4) Get state id, and add transition
						tsets.each do |ttoken, tset|
							ttype, tsym = ttoken
							
							tset.rules.each {|rule| rule.advance}
							
							tset = close_set(tset)
							
							id = @table.get_state_id(tset)
							
							#Add Goto and Shift actions.
							if ttype == :NONTERM
								row.on(ttoken, Table::GoTo.new(id))
							else
								row.on(ttoken, Table::Shift.new(id))
							end
						end
						
						#Find the Accept and Reduce actions for this set.
						row.rules.each do |rule|
							if rule.tokens[-1].type == :DOT
								if rule.symbol == :'!start'
									row.on([:TERM, :EOS], Table::Accept.new)
								else
									row.on(nil, Table::Reduce.new(rule.id))
								end
							end
						end
					end
					
					#Print the table if requested.
					self.explain(explain_file) if explain_file
					
					#Remove references to the RuleProxy and Item list.
					@proxy = @rules = nil
					
					#Drop the sets from the table.
					@table.drop_sets
				end
				
				def self.get_question(token)
					new_symbol	= ('!' + token.value.to_s + '_question').to_sym
					new_token		= Token.new(:NONTERM, new_symbol)
					
					if not @items.has_key?(new_token.value)
						#Add the items for the following productions:
						#
						#token_question: | token
						
						#1st (empty) production.
						@items[new_symbol] << Rule.new(@proxy.next_id, new_symbol, [Token.new(:DOT)]) { nil }
						
						#2nd production
						@items[new_symbol] << Rule.new(@proxy.next_id, new_symbol, [Token.new(:DOT), token]) {|v| v[0]}
					end
					
					return new_token
				end
				
				def self.get_plus(token)
					new_symbol	= ('!' + token.value.to_s + '_plus').to_sym
					new_token		= Token.new(:NONTERM, new_symbol)
					
					if not @items.has_key?(new_token.value)
						#Add the items for the following productions:
						#
						#token_plus: token | token token_plus
						
						#1st production
						@items[new_symbol] << Rule.new(@proxy.next_id, new_symbol, [Token.new(:DOT), token]) {|v| [v[0]]}
						
						#2nd production
						@items[new_symbol] << Rule.new(@proxy.next_id, new_symbol, [Token.new(:DOT), token, new_token]) {|v| [v[0]] + v[1]}
					end
					
					return new_token
				end
				
				def self.get_star(token)
					new_symbol	= ('!' + token.value.to_s + '_star').to_sym
					new_token		= Token.new(:NONTERM, new_symbol)
					
					if not @items.has_key?(new_token.value)
						#Add the items for the following productions:
						#
						#token_star: | token token_star
						
						#1st (empty) production
						@items[new_symbol] << Rule.new(@proxy.next_id, new_symbol, [Token.new(:DOT)]) { [] }
						
						#2nd production
						@items[new_symbol] << Rule.new(@proxy.next_id, new_symbol, [Token.new(:DOT), token, new_token]) {|v| [v[0]] + v[1]}
					end
					
					return new_token
				end
				
				def self.rule(symbol, expression = nil, &action)
					#Convert the 'symbol' to a Symbol if it isn't already.
					symbol = symbol.to_sym if not symbol.is_a?(Symbol)
					
					#Set the start symbol if this is the first production
					#defined.
					@start_symbol ||= symbol
					
					#Set the symbol in the RuleProxy.
					@proxy.symbol = symbol
					
					if expression
						@rules[symbol] << @proxy.clause(expression, &action)
					else
						@rules[symbol] += @proxy.wrapper(&action)
					end
				end
				
				def self.start(symbol)
					@start_symbol = symbol
				end
				
				####################
				# Instance Methods #
				####################
				
				def parse(tokens)
					#Start out with one stack in state zero.
					stacks = [ParseStack.new]
					
					tokens.each do |token|
						new_stacks = []
						
						stacks.each do |stack|
							actions = @table[stack.state].on?([token.type, toke.value])
							
							if actions.length == 0
								stacks.delete(stack)
									
								#Check to see if we removed the last stack.
								if stacks.length == 0
									raise ParsingError, 'Out of actions.'
								end
							else
								actions.each do |action|
									new_stacks << (new_stack = stack.clone)
									
									case action.class
										when Accept
											
										
										when Reduce
											
										
										when Shift
											new_stack << action.id
									end
								end
							end
						end
						
						stacks = new_stacks
					end
					
					#Check to see if any of the stacks are in an accept
					#state.  If multiple stacks are in accept states throw
					#an error.  Otherwise reutrn the result of the user
					#actions.
					stacks.inject(nil) do |result, stack|
						if @table[stack.state].on?(:EOS)
							if result
								raise ParsingError, 'Multiple derivations possible.'
							else
								stack.output_stack
							end
						else
							result
						end
					end
				end
			end
		end
		
		class ParseStack
			attr_reader :output_stack
			attr_reader :state_stack
			
			def initalize(other)
				if other
					@output_stack	= other.output_stack.copy
					@state_stack	= other.state_stack.copy
				else
					@output_stack	= [ ]
					@state_stack	= [0]
				end
			end
			
			def push_state(state)
				@state_stack << state
			end
			
			def pop_state(n = 1)
				@state_stack.pop(n)
			end
			
			def state
				@state_stack.last
			end
		end
		
		class Rule
			attr_reader :id
			attr_reader :symbol
			attr_reader :tokens
			attr_reader :action
			
			def initialize(id, symbol, tokens, &action)
				@id		= id
				@symbol	= symbol
				@tokens	= tokens
				@action	= action || Proc.new {}
				
				@dot_index = @tokens.index {|t| t.type == :DOT}
			end
			
			def ==(other)
				self.action == other.action and self.tokens == other.tokens
			end
			
			def advance
				if (index = @dot_index) < @tokens.length - 1
					@tokens[index], @tokens[index + 1] = @tokens[index + 1], @tokens[index]
					@dot_index += 1
				end
			end
			
			def copy
				Rule.new(@id, @symbol, @tokens.clone, &@action)
			end
			
			def next_token
				@tokens[@dot_index + 1]
			end
			
			def to_s(padding = 0, item_mode = false)
				"#{format("%-#{padding}s", @symbol)} -> #{@tokens.map{|t| if t.type == :DOT and item_mode then '·' else t.value end}.join(' ')}"
			end
		end
		
		class RuleProxy
			attr_writer :symbol
			
			def initialize(parser)
				@parser = parser
				
				@lexer = EBNFLexer.new
				@rules = Array.new
				
				@rule_counter = 0
				@symbol = nil
			end
			
			def clause(expression, &action)
				tokens = @lexer.lex(expression)
				
				new_tokens = [Token.new(:DOT)]
				
				#Remove EBNF tokens and replace them with new productions.
				tokens.each_index do |i|
					ttype0 = tokens[i].type
					
					if ttype0 == :TERM or ttype0 == :NONTERM
						if i + 1 < tokens.length
							ttype1 = tokens[i + 1].type
							
							new_tokens <<
							case tokens[i + 1].type
								when :'?'
									@parser.get_question(tokens[i])
								
								when :*
									@parser.get_star(tokens[i])
								
								when :+
									@parser.get_plus(tokens[i])
								
								else
									tokens[i]
							end
						else
							new_tokens << tokens[i]
						end
					end
				end
				
				#Add the item to the current list.
				@rules << (rule = Rule.new(self.next_id, @symbol, new_tokens, &action))
				
				#Return the item from this clause.
				return rule
			end
			
			def next_id
				@rule_counter += 1
			end
			
			def wrapper(&block)
				@rules = Array.new
				
				self.instance_exec(&block)
				
				return @rules
			end
		end
		
		class Set
			attr_reader :rules
			
			def initialize(rules = [])
				@rules = rules
			end
			
			def ==(other)
				self.rules == other.rules
			end
			
			def <<(rule)
				if not @rules.include?(rule) then @rules << rule end
			end
			
			def append(new_rules)
				new_rules.each {|rule| self << rule}
			end
			
			def each
				@rules.each {|r| yield r}
			end
		end
		
		class Table
			attr_reader :rows
			
			def initialize
				@row_counter = -1
				@rows = Array.new
			end
			
			def [](index)
				@rows[index]
			end
			
			def add_state(set)
				@rows << Row.new(@rows.length, set)
				
				return @rows.length - 1
			end
			
			def drop_sets
				@rows.each {|row| row.drop_set}
			end
			
			def each
				@rows.each {|r| yield r}
			end
			
			def get_state_id(set)
				if (id = @rows.index {|row| row.set == set}) then id else self.add_state(set) end
			end
			
			class Row
				attr_reader :id
				attr_reader :set
				attr_reader :actions
				
				def initialize(id, set)
					@id		= id
					@set		= set
					@actions	= Hash.new {|h,k| h[k] = Array.new}
				end
				
				def drop_set
					@set = nil
				end
				
				def on(symbol, action)
					@actions[symbol] << action
				end
				
				def on?(symbol)
					@actions[nil] | @actions[symbol]
				end
				
				def rules
					@set.rules
				end
			end
			
			class Action
				attr_reader :id
				
				def initialize(id = nil)
					@id = id
				end
				
				def to_s
					"#{self.class.name.split('::').last}" + if @id then " #{@id}" else '' end
				end
			end
			
			class Accept	< Action; end
			class GoTo	< Action; end
			class Reduce	< Action; end
			class Shift	< Action; end
		end
	end
end
