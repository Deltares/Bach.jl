# Plotting functions

using PlotUtils
using Makie
using GraphMakie
using Colors
using FixedPointNumbers
using Graphs
import NetworkLayout
using Printf

"Create a time axis"
function time!(ax, time)
    # note that the used x values must also be in unix time
    dateticks = optimize_ticks(time[begin], time[end])[1]
    ax.xticks[] = (datetime2unix.(dateticks), Dates.format.(dateticks, "yyyy-mm-dd"))
    ax.xlabel = "time"
    ax.xticklabelrotation = π / 4
    return ax
end

"""
    reconstruct_graph(systems::Set{ODESystem}, eqs::Vector{Equation})

Based on a list of systems and their connections, construct a graph that shows the connections between the systems, through their connectors.
Both systems and connectors are separately included in the graph.

Returns the graph, as well as the names of the systems and connectors:
    g, component_names, connector_names
"""
function reconstruct_graph(systems::Set{ODESystem}, eqs::Vector{Equation})
    # get the names and number of connectors
    connector_names_set = Set{Symbol}()
    for eq in eqs
        for inner in eq.rhs.inners
            push!(connector_names_set, nameof(inner))
        end
    end
    connector_names = collect(connector_names_set)
    component_names = nameof.(systems)
    n_component = length(systems)
    n_connector = length(connector_names)

    # the first n_component nodes are reserved for the components, the rest for the connectors
    g = Graph(n_component + n_connector)
    # add edges of the connetions
    for eq in eqs
        from, tos = Iterators.peel(eq.rhs.inners)
        i_from = findfirst(==(nameof(from)), connector_names) + n_component
        for to in tos
            i_to = findfirst(==(nameof(to)), connector_names) + n_component
            add_edge!(g, i_from, i_to)
        end
    end

    # add edges of the components to their own connectors
    for (i_from, component_name) in enumerate(component_names)
        for (i_to, connector_name) in enumerate(connector_names)
            parent_name = parentname(connector_name)
            if component_name == parent_name
                add_edge!(g, i_from, i_to + n_component)
            end
        end
    end

    return g, component_names, connector_names
end

"""
    reconstruct_graph(systems::Set{ODESystem}, eqs::Vector{Equation})

Based on a list of systems and their connections, create an interactive graph plot
that shows the components and their values over time.
"""
function graph_system(systems::Set{ODESystem}, eqs::Vector{Equation}, reg::Register)
    g, component_names, connector_names = reconstruct_graph(systems, eqs)
    n_component = length(component_names)
    n_connector = length(connector_names)
    n = n_component + n_connector

    # different edge color for inside and outside components
    node_color = fill(colorant"black", n)
    edge_color = RGB{N0f8}[]
    for edge in edges(g)
        colour = if src(edge) <= n_component
            colorant"black"
        else
            colorant"blue"
        end
        push!(edge_color, colour)
    end

    vars = ["h", "S", "Q", "C"]
    var = "Q"

    times = timeseries(reg)  # TODO remove
    starttime = first(times)
    endtime = last(times)
    t = starttime .. endtime
    ts = lastindex(times)  # TODO remove
    fig = Figure()

    layout_graph = fig[1, 1]
    layout_time = fig[1, 2]

    # left column: graph
    menu = Menu(fig, options = vars)
    ls = labelslider!(
        fig,
        "time:",
        times;
        format = x -> @sprintf("%.1f s", x),
        sliderkw = Dict(:startvalue => times[end]),
    )

    layout_graph[1, 1] = menu
    layout_graph[2, 1] = ls.layout
    ax = Axis(layout_graph[3, 1])

    # create labels for each node
    labelnames = String.(vcat(component_names, connector_names))
    # not all states have all variables

    # TODO pre calculate all interpolation functions?
    # TODO rename col (no dataframe columns)
    # ts does not need to interpolate perhaps, do that only for the time plots?
    # e.g. labels don't need to be interpolated
    function create_nlabels(var, ts)
        labelvars = string.(labelnames, "₊$var")
        return [
            string(col, @sprintf(": %.2f", savedvalue(reg, Symbol(col), ts))) for
            col in labelvars
        ]
    end

    nlabels = create_nlabels(var, ts)
    nlabels_textsize = 15.0

    # needed for hover interactions to work
    node_size = fill(10.0, nv(g))
    edge_width = fill(2.0, ne(g))
    # layout of the graph (replace with geolocation when they have one)
    # layout = NetworkLayout.Spring() # ok
    layout = NetworkLayout.Stress() # good (doesn't seem to work for disconnected graphs)

    p = graphplot!(
        ax,
        g;
        nlabels,
        nlabels_textsize,
        node_size,
        node_color,
        edge_width,
        edge_color,
        layout,
    )

    # right column: timeseries
    h = Axis(layout_time[1, 1], ylabel = "h [m]")
    hidexdecorations!(h, grid = false)
    # axislegend()
    s = Axis(layout_time[2, 1], ylabel = "S [m³]")
    hidexdecorations!(s, grid = false)
    # axislegend()
    q = Axis(layout_time[3, 1], ylabel = "Q [m³s⁻¹]")
    hidexdecorations!(q, grid = false)
    # axislegend()
    c = Axis(layout_time[4, 1], ylabel = "C [kg m⁻³]")
    hidexdecorations!(c, grid = false)
    # axislegend()

    linkxaxes!(h, s, q, c)

    # state of which timeseries to draw
    draw_timeseries = fill(false, n)

    # interactions
    function node_click_action(idx, args...)
        # flip the switch
        oldstate = draw_timeseries[idx]
        draw_timeseries[idx] = !oldstate
        idxs = findall(draw_timeseries)
        # color = p.node_color[][idx]
        black, red = colorant"black", colorant"red"
        if !oldstate
            p.node_color[][idx] = red
        else
            p.node_color[][idx] = black
        end
        p.node_color[] = p.node_color[]

        label_sels = labelnames[idxs]
        empty!(h)
        empty!(s)
        empty!(q)
        empty!(c)
        for label_sel in label_sels
            col = string(label_sel, "₊h")
            ifunc = interpolator(reg, Symbol(col))
            scatterlines!(h, t, ifunc, label = label_sel)

            col = string(label_sel, "₊S")
            ifunc = interpolator(reg, Symbol(col))
            scatterlines!(s, t, ifunc, label = label_sel)

            col = string(label_sel, "₊Q")
            ifunc = interpolator(reg, Symbol(col))
            scatterlines!(q, t, ifunc, label = label_sel)

            col = string(label_sel, "₊C")
            ifunc = interpolator(reg, Symbol(col))
            scatterlines!(c, t, ifunc, label = label_sel)
        end

        # TODO remove the old lines
        # axislegend(h)
    end

    on(menu.selection) do var
        p.nlabels[] = create_nlabels(var, ts)
        # https://github.com/JuliaPlots/GraphMakie.jl/issues/66
        p.nlabels_distance[] = p.nlabels_distance[]
    end

    lift(ls.slider.value) do t
        ts = searchsortedlast(times, t)
        p.nlabels[] = create_nlabels(var, ts)
        p.nlabels_distance[] = p.nlabels_distance[]
    end

    deregister_interaction!(ax, :rectanglezoom)
    register_interaction!(ax, :nhover, NodeHoverHighlight(p))
    register_interaction!(ax, :ehover, EdgeHoverHighlight(p))
    register_interaction!(ax, :ndrag, NodeDrag(p))
    register_interaction!(ax, :edrag, EdgeDrag(p))
    register_interaction!(ax, :nclick, NodeClickHandler(node_click_action))

    return fig
end

nothing
