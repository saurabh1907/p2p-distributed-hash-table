
if length(System.argv()) == 3 do
   [numnodes, numrequests, percentage] = System.argv()

numnodes = String.to_integer(numnodes)
numrequests = String.to_integer(numrequests)
percentage = String.to_integer(percentage)

App.main(numnodes, numrequests, percentage )
else
  [numnodes, numrequests] = System.argv()
  numnodes = String.to_integer(numnodes)
  numrequests = String.to_integer(numrequests)
  App.main(numnodes, numrequests, 0)
end

